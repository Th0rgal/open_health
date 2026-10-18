# Sleep staging: matching the official Oura app's hypnogram

The hypnogram in the official app (Android 7.18.0) comes from **NSSA**, Oura's
`sleepstaging_2_6_0` TorchScript model (`NssaPyTorchModel`, `PyTorchModelType.SLEEPSTAGING`),
run once per ring bedtime. `sleepnet_moonstone_1_2_0` (`SleepNetApneaPyTorchModel`) also
returns stages, but the app only keeps its apnea and SpO₂ outputs (`SleepNetHandler.b` builds a
`DbApnea`). Both clients used moonstone's stages until October 2026, and that was the root of
the mismatch.

This repository stages with the Rust port of that pipeline (open_oura,
`oura_analysis::ported::sleepstaging`). Its classifier is either a community-trained tree
ensemble that approximates the official staging (the built-in stager) or the vendor forest
extracted from the vendor native library (the `official` stager, "Oura model" in the clients). Neither needs
a model runtime. See [Choosing the stager](#choosing-the-stager).

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

The graph calls five native ops from the vendor library. The Rust port reimplements the four
signal-processing ops (`oura_create_windows`, `oura_find_indices`, `oura_biquad_cascade`,
`oura_find_peaks`) inside the feature pipeline. The
fifth, `oura_sleep_classifier`, is a treelite forest of 2000 trees, 4 classes, 182 features and
63 code units.

- `tools/extract_nssa_classifier.py` lifts it symbolically from the arm64 code into `sleepstaging_2_6_0_classifier.bin` (magic `NSSAFOR1`, 7.3 MB).
- That file holds Oura's weights. It is produced locally from a library the user supplies and is never committed.
- NaN becomes a treelite "missing" entry.
- Units are summed in native `fadd` order, then softmax, then a cast to float32.
- `oura_analysis::ported::sleepstaging::vendor_forest` reads the file and implements the same evaluation in Rust.

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
| 1 | `sleepnet_moonstone_1_2_0` stages | `sleepstaging_2_6_0` (NSSA). The Rust port runs its pipeline, and the extracted forest runs its classifier. |
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
| 12 | Web dashboard: the Python batch exceeded the 180 s timeout on a full DB, so the web showed the signal fallback | Staging runs in process in Rust. Results are cached per input fingerprint (`official_stage_cache.json`, `xgb_stage_cache.json`). |

## Verification

The fixtures are synthetic. Personal ring data stays local.

- **Classifier**
  - Lifted DAG vs the native units under unicorn: 18,900/18,900 bit-exact.
  - Full `predict_multiclass`, margins and probabilities: 2000/2000 bit-exact.
  - Exported blob vs the lifter: 3000/3000.
  - The Rust reader gives the same probabilities as the Python `Forest` loader (`tools/nssa_classifier.py`) on 14,378 rows.
- **IBI correction**: the Python port matches emulated libappecore on the real night and on 160 synthetic streams.
- **0x60 decoder**: identical to the native decoder on all 106,797 rows.
- **Rust path against the graph and the app** (one wearer, 14 nights, 30 s epochs): Rust features with the vendor forest, which also decides the wake-trim rerun, agree with the TorchScript graph on 0.9999 of epochs (1 of about 12,500) and with the official app's stages on 0.998 (the graph itself: 0.998). The built-in stager agrees with the app on about 0.92. With the surrogate deciding the rerun and the forest classifying, agreement with the app is 0.9935, so the forest has to drive the rerun. The remaining differences come from breathing-rate features in `hrv_low`.
- **Fixture parity**: `crates/oura-summary/tests/nssa_parity.rs` checks `apps/ios/OuraApp/Tests/NssaParityFixture.json` (written by `tools/make_nssa_fixture.py` from the Python reference in `tools/nssa_inputs.py` and `tools/ibi_correction.py`) against the Rust code:
  - sleep ACM decode (`oura_protocol`, 40 bodies, to the decoder's 4-decimal rounding) and the model column order;
  - sleep temperature decode and 30 s spacing;
  - IBI correction (`oura_analysis::ported::ibi_correction::correct_ibis`), bit-exact on 6 streams;
  - 5-minute aggregation (`aggregate_30s_to_5min`).
- **Fixture fields with no Rust test.** The IBI beat expansion with clamping (`ibi_events`) and the inclusive window (`ibi_windows`) have no separate Rust function: `sleepstaging::events::collect` expands and filters inline and does not clamp stamps (the corrector drops beats that go back in time instead). The demographics vector is not in the fixture; `profile_scalars` encodes sex as 2 (male), 1 (female) and -1, where the Python reference used 1, -1 and 0, and truncated age to an integer. None of the three scalars is a classifier column.

## Still unconfirmed without an official export

- **Exact bedtime.** Accounts with stateless bedtime detection derive the period differently, and our ring-time → UTC conversion is `RingClock`, not the parser's `TimeMapping`. A shift of one second or more can move the floor30 grid by one epoch.
- **Profile.** Age and BMI buckets of 5 and sex must equal the Oura account profile. Ours is `profile.json` or HealthKit.
- **`exp`.** The softmax was checked against the host libm, not bionic's `exp`. This can only flip an argmax on an exact tie.
- **ecore slot rounding.** ecore's re-grid places phase i at round30(bedtimeStart_s + 30·i). When the start's sub-30 s offset is ≥ 15 s, the stored string might shift by one slot. This was not disassembled to the end.

## Choosing the stager

Both stagers run the same Rust feature pipeline, wake-trim rerun, smoothing, bedtime grid and
false-nap check (`stage_night_forest` with the rerun and the false-nap check on, and
`stage_night_default` for the built-in trees). They differ in the classifier:

- `official` ("Oura model"): the vendor forest in `sleepstaging_2_6_0_classifier.bin`. The
  hypnogram carries source `nssa`, so the brain shows it verbatim and labels the 5-minute lane
  "Oura app".
- `xgb` ("Built-in"): a community-trained tree ensemble that approximates the official staging,
  compiled into open_oura. It needs no files.

The choice is `"sleep_stager"` in `profile.json`, resolved by `oura_summary::sleep_stager` and
set from the profile screen of either client or `oura dashboard --sleep-stager`. Automatic mode
uses `official` when the classifier file is registered and valid, otherwise `xgb`. An
unavailable option is not offered and carries a notice.

**Producing the classifier file.** The file is extracted from the vendor library and stays on
the local machine:

```sh
python tools/extract_nssa_classifier.py config.arm64_v8a.apk
```

The script needs the vendor native library (from the APK) and the packages listed in its header.
Place the output in the models directory (web; `$OURA_MODELS_DIR` overrides the directory) or add it
to the iOS bundle as `sleepstaging_2_6_0_classifier.bin` (optional resource in `project.yml`).
Both files are gitignored. There is no graph (`.pt` or `.ptl`) requirement.
