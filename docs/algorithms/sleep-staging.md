# Sleep staging: matching the official Oura app's hypnogram

The hypnogram in the official app (Android 7.18.0) comes from **NSSA**, Oura's
`sleepstaging_2_6_0` TorchScript model (`NssaPyTorchModel`, `PyTorchModelType.SLEEPSTAGING`),
run once per ring bedtime. `sleepnet_moonstone_1_2_0` (`SleepNetApneaPyTorchModel`) also
returns stages, but the app only keeps its apnea and SpO₂ outputs (`SleepNetHandler.b` builds a
`DbApnea`). Both clients used moonstone's stages until October 2026, and that was the root of
the mismatch.

## The official pipeline

| Step | Android code | What it does |
| --- | --- | --- |
| Bedtime | `NssaManager.queueBedtimePeriods` → `bedtimeperiod.a` → `DbSleepInterimResult` | Each ring `bedtime_period` (0x76) becomes an interim result keyed by its start. A later 0x76 with the same start replaces it. Start and end are the ring times converted to UTC ms by the parser's time mapping (`parse_api_bedtime_period` @0x2afab8). A feature-flagged "stateless bedtime detection" can replace ring bedtimes; its model is not in the APK. |
| Raw events | `NssaSleepPhasesHandler.a` | DbRawEvents whose time is inside [start, end]: {0x76, 0x72}, {0x60}, {0x75}. |
| ACM | `SleepAcmPeriodExtKt`, `parse_api_sleep_acm_period` @0x2bf39c | **One** 30 s window per 0x72 event, six float32 statistics. Bytes 0–5 are finger angle `int + frac/255` (tmean, max, iqr). Bytes 6–11 are MAD `12-bit/4095 + high nibble` (tmean, max, iqr). Model column order: `[madIqr, madMax, madTrimmedMean, fingerAngleIqr, fingerAngleMax, fingerAngleMean]`. |
| IBI | `parse_api_ibi_and_amplitude_event` @0x2be468, then ecore `correctIbiAndAmplitudeEvents` | Only 0x60 (never 0x80). Beat *k* is stamped at the **start** of its interval: event time − (ibi_k + … + ibi_5). Stamps are clamped so they never go backwards. Then libappecore's `rr_correction_run_ex` produces `(ts, ibi, amp, validity)`; see validity codes below. |
| Temperature | `parse_api_sleep_temp_event` @0x2be9e0 | 0x75 only. Sample *i* of *n* (centi-°C, float32) is stamped at event − (n−1−i)·30 s. |
| Window | `RingEventParserExtKt.indexOfFirstAndLastOrNull` + `subListInclusive` | Each stream keeps the items from the first to the last one stamped inside [start, end], inclusive. |
| Demographics | `DbUserSettingsUtils` | `[age (int years), BMI = kg/m², sex (F −1, M 1, other 0)]`. Inside the model, age and BMI are rounded to the nearest 5. |
| Model | `sleepstaging_2_6_0` forward | Feature extraction, tree classifier, smoothing (thresh 0.2, weights [0.5, 1, 0.5], wake skipped), a wake-crop rerun, the bedtime grid `arange(floor30(start), floor30(end), 30 s)` with missing epochs set to WAKE, and the false-nap check. All of this is in the graph. |
| Store | `settings.fragment.health.c` (case 3) → `SleepHandler.calculateSleep` → ecore `calculate_sleep_score_numerical` | The digits pass through unchanged. Epoch *k* starts at floor30(bedtime start) + 30·k. |
| Display | `DbSleepExtKt.sleepPhases5Min` → `SleepPhaseConverter.aggregate30SecTo5Min` | The sleep chart draws **5-minute blocks**: windows of 10 epochs; a last window shorter than 5 is dropped; ≥4 awake epochs → AWAKE; otherwise the mode, with ties broken AWAKE > DEEP > REM > LIGHT. |

The graph calls five native ops from `libalgos.so`. We reimplement them in
`apps/ios/OuraApp/NssaOps.c`, which the iOS app compiles and the desktop runner loads through
ctypes. `tools/nssa_ops.py` holds the pure-Python reference.

- `oura_create_windows` @0x5602fc
- `oura_find_indices` @0x561248: running "low" index; the first probe is x[j+1].
- `oura_biquad_cascade` @0x55e860 / step @0x564234: TDF-II with float32 `fmadd`.
- `oura_find_peaks` @0x55ee1c: scipy's `_local_maxima_1d`.
- `oura_sleep_classifier`: a treelite forest of 2000 trees, 4 classes, 182 features and 63 code units.
  - `tools/extract_nssa_classifier.py` lifts it symbolically from the arm64 code into `sleepstaging_2_6_0_classifier.bin`.
  - That file holds Oura's weights, so it is gitignored next to the models.
  - NaN becomes a treelite "missing" entry.
  - Units are summed in native `fadd` order, then softmax, then a cast to float32.

**IBI validity** (ecore `rr_validity_indicator_t`):

| Code | Meaning |
| --- | --- |
| 0 | First beat |
| 1 | Valid |
| 2 | Invalid (amplitude zeroed) |
| 3 | Gap refilled or redistributed |

Correction init: at most 4 outputs per call, max gap 5000 ms, HR mode, max HR 150. Output lags by about 6 beats, and beats still buffered at the end are dropped.

## What we did differently (fixed)

| # | Ours before | Official |
| --- | --- | --- |
| 1 | `sleepnet_moonstone_1_2_0` stages (tools/run_sleep_model.py, iOS SleepStaging.swift) | `sleepstaging_2_6_0` (NSSA). Its five custom ops are now implemented. |
| 2 | Motion input = `motion_seconds` from 0x47 | 0x72 `sleep_acm_period`: one 30 s window, six statistics in the column order above. Our decoder also labelled all six `acm_mad` and rounded them to 4 decimals. |
| 3 | IBI validity = 300–2000 ms plus a "tail noise" heuristic; 0x80 beats merged in; beats synthesized from 0x5D when IBI was missing | 0x60 only, corrected by ecore. On 2026-10-15 ecore flags 1,202 of 23,178 beats invalid and refills 660; the old rule accepted all of them. |
| 4 | Beat k stamped event time + cumulative IBI (about one packet, ~5 s, too late), no clamping | Event time − IBIs that follow, clamped to be non-decreasing. |
| 5 | Temperature = mean of each 0x75 event at the event time, or 0x46 as a fallback | Every 0x75 sample, 30 s apart. 0x46 is never used. |
| 6 | Inputs taken from ±10 min around the window; window = the summary's extended or merged night | Exactly the ring bedtime(s) inside the night, each staged separately. |
| 7 | Scalars `[35, 25, 0, 0, 0]` and TST = 300 (moonstone's demographics and ring type) | `[age, BMI, sex]` from the profile. |
| 8 | `refine_deep_stages` invented N3 when the model had no deep sleep (Python, Rust `refine_deep_stages_with_hrv`, Swift `refineDeepStages`) | No such step. Now only the signal-based fallback uses it. |
| 9 | A second 5-epoch majority filter (`smooth_stages` / `Sleep.smooth`) on every hypnogram | Smoothing happens only inside the graph. Oura stagings (`nssa`, `ring`) are now used verbatim. |
| 10 | Epochs assumed end-stamped and laid on a grid starting at `start_ds` | The grid is wall-clock aligned to floor30(bedtime start). Epochs land on the summary grid by midpoint; `stages_t0_unix` and `nssa_periods` keep the exact times. |
| 11 | 30 s hypnogram only | Official chart = 5-min blocks (`stages_5min`, new "Stages · 5 min (Oura app)" lane). |
| 12 | Web dashboard: the Python batch exceeded the 180 s timeout on a full DB, so the web showed the signal fallback | The C ops make NSSA run all nights in about 60 s. Results are cached per input fingerprint (`nssa_cache.json`). |

## Verification

The fixtures are synthetic. Personal ring data stays local.

- **Classifier**
  - Lifted DAG vs the native units under unicorn: 18,900/18,900 bit-exact.
  - Full `predict_multiclass`, margins and probabilities: 2000/2000 bit-exact.
  - Exported blob vs the lifter: 3000/3000.
  - C vs numpy: `tools/test_nssa_ops.py`.
- **IBI correction**: the Python port matches emulated libappecore on the real night and on 160 synthetic streams.
- **0x60 decoder**: identical to the native decoder on all 106,797 rows.
- **Ops**
  - Biquad step: emulated, 60,000 fuzz cases bit-exact.
  - The other three ops: transcribed and cross-checked by reading the code.
  - C and Python twins are bit-identical (`tools/test_nssa_ops.py`).
- **Lite interpreter**: `sleepstaging_2_6_0.ptl` loaded in the lite interpreter gives the same epochs as the full model. The model's own `aggregate_30sec_to_5min` equals the Kotlin rule.
- **Swift twins**: `apps/ios/OuraApp/Tests/NssaParityFixture.json` (written by `tools/make_nssa_fixture.py`) pins the Swift input builder, the IBI correction and the 5-min aggregation to the Python outputs.

## Still unconfirmed without an official export

- **Exact bedtime.** Accounts with stateless bedtime detection derive the period differently, and our ring-time → UTC conversion is `RingClock`, not the parser's `TimeMapping`. A shift of one second or more can move the floor30 grid by one epoch.
- **Profile.** Age and BMI buckets of 5 and sex must equal the Oura account profile. Ours is `profile.json` or HealthKit.
- **`exp`.** The softmax was checked against the host libm, not bionic's `exp`. This can only flip an argmax on an exact tie.
- **ecore slot rounding.** ecore's re-grid places phase i at round30(bedtimeStart_s + 30·i). When the start's sub-30 s offset is ≥ 15 s, the stored string might shift by one slot. This was not disassembled to the end.

## Choosing the stager

The clients can stage with the NSSA graph above or with the built-in Rust stager (open_oura's
`sleepstaging` port with a compiled-in tree ensemble trained privately by the author). The choice
is `"sleep_stager"` in `profile.json`, resolved by `oura_summary::sleep_stager` and set from the
profile screen of either client or `oura dashboard --sleep-stager`. NSSA needs
`sleepstaging_2_6_0` (`.pt` on desktop, `.ptl` on iOS) and `sleepstaging_2_6_0_classifier.bin`.
When either is missing the option is disabled with a notice and automatic mode uses the built-in
stager. The built-in stager reads the same bedtime inputs (`stager_inputs`) and its classifier
format differs from the extracted forest, so the Rust pipeline does not load the NSSA classifier.
Both stagers feed the same 30 s grid, the 5-minute lane and the sleep score.
