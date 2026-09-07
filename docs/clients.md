# Three clients, one core — keep them in sync

open_oura has **three user-facing clients that render the same health data**. When you
add or change a feature, you almost always have to touch **all of them**. This is the map.

| | Web dashboard | Native iOS app | Native Android app |
| --- | --- | --- | --- |
| Where | `dashboard/web/` (vanilla HTML/CSS/JS) served by `crates/oura-cli/src/dashboard.rs` | `apps/ios/OuraApp/` (SwiftUI) on `crates/oura-core` (UniFFI) | `apps/android/app/` (Jetpack Compose) on `crates/oura-core` (UniFFI) |
| Entry | `oura dashboard` → `http://127.0.0.1:8090` | `apps/ios/OuraApp/build_run.sh` (model-free) / `build_run_torch.sh` (on-device models) | `./gradlew :app:assembleLiteDebug` (model-free) / `assembleFullDebug` (on-device models) |
| Render code | `app.js`, `styles.css`, `index.html` | `OuraApp.swift`, `Theme.swift` | `ui/RootScreen.kt`, `ui/Theme.kt` |
| Models run via | Python torch runners (`tools/run_*_model.py`) | on-device `.ptl` (`TorchBridge.{h,mm}` + `SleepStaging`/`CvaModel`/`ActivityModel.swift`) | on-device `.ptl` (`cpp/torch_bridge.cpp` JNI + `models/{SleepStaging,CvaModel,ActivityModel,IllnessModel}.kt`) |

The two native clients are near-identical by construction: they consume the **same**
`crates/oura-core` UniFFI surface, differing only in the bindings language
(`--language swift` vs `--language kotlin` from the same `uniffi-bindgen` binary) and in
the platform layers — BLE transport, UI toolkit, torch bridge, and health export.

## The one shared brain: `crates/oura-summary`

`oura_summary::build_summary()` computes **the summary JSON all three clients render** —
vitals, per-night stats, the digest, the MET activity profile, steps/kcal, device health. The
web calls it in `dashboard.rs`; iOS and Android call it through `oura-core`'s `summary_json()`
FFI. The models are injected via the `ModelRunner` trait (web: `PythonRunner`; iOS and
Android: `NoModelRunner` + their own on-device torch code).

The non-model math is the **ported ecore ground truth** from `crates/oura-analysis`
(`ported::{spo2, temperature, metabolic, baseline}`): SpO₂ calibration, nightly skin
temperature, Schofield BMR (→ `total_kcal`), Jackson VO₂max, steps→distance, and the
annealing-EMA personal baseline behind each vital's `delta_pct`. Add a new derived
metric there once and both clients receive it in the JSON.

**So the rule of thumb:**

- **A new computed metric / field** → add it once in `oura-summary` (`build_summary`). Every
  client receives it in the JSON. Then render it in **`app.js`, `OuraApp.swift` and
  `RootScreen.kt`**.
- **A new visualization / UI** (no new data) → do it in **all three**.
- **A new model** → wire **every** runner: a `tools/run_*_model.py` (used by `PythonRunner`),
  an `oura_*` function in `TorchBridge.mm` + a Swift `*Model.swift`, and the matching JNI
  entry in `cpp/torch_bridge.cpp` + a Kotlin `models/*.kt` — each building the same input
  tensors and folding the result into the summary.

## Feature ↔ feature correspondence

| Feature | Web (`app.js`) | iOS (`OuraApp.swift`) | Android (`ui/`) | Data (JSON key) | Model |
| --- | --- | --- | --- | --- | --- |
| Digest headline | `load()` digest | `RootView` digest | `RootScreen` digest | `digest` | — |
| Vitals (HRV/RHR/temp/SpO₂) | `renderTiles` / `VitalCell`-like | `VitalCell` | `VitalCell` (Atoms.kt) | `vitals`, `nights[]` | — |
| **Unified day (night + activity)** | `renderDay`, `dayCard` | `TodayCard` | `TodayCard` | `nights[]`, `activity*` | — |
| **Full-page sleep report** (polysomnograph + clinical metrics + interpretation) | `openDayPage`→`sleepReport`, `polysomnograph`, `hypnoSvg` | `DayReportView`→`SleepReport`, `Polysomnograph` (Reports.swift) | `DayReportScreen`→`SleepReport`, `Polysomnograph` (Reports.kt) | `nights[].{stages_full,series,metrics}` | SleepNet |
| **Sleep debt** (14-day card + cumulative debt / total sleep detail) | `renderSleepDebt`→`openSleepDebt` | `SleepDebtCard`→`SleepDebtDetail` | `SleepDebtCard`→`SleepDebtDetail` | `sleep_debt`, grouped by wake date including naps | SleepNet |
| **Full-page activity report** (24h MET profile + intensity metrics) | `openDayPage`→`activityReport`, `metProfileSvg` | `DayReportView`→`ActivityReport`, `MetProfile` (Reports.swift) | `DayReportScreen`→`ActivityReport`, `MetProfile` (Reports.kt) | `activity_profile`, `activity_daily`, `activity` | AAD |
| Stage breakdown | `stageBar` | `StageBreakdown` | `StageBar` (Charts.kt) | `nights[].{deep,light,rem,wake}_pct` | SleepNet |
| **Autonomic recovery by stage** (mean HR/HRV in deep/light/REM) | `sleepReport` autonomic grid | `SleepReport` `autonomicGrid` | `SleepReport` autonomic grid | `nights[].autonomic` | SleepNet (needs hypnogram) |
| **Cardiovascular age** | `renderCardio` | Cardio section | Cardio section | `cardio` | CVA (web: Python · native: `CvaModel`) |
| **VO₂max estimate** | `renderCardio` | Fitness section | Fitness section | `fitness.vo2max` | — (Jackson, model-free) |
| Movement ridge | `ridgeSvg` | `MovementRidge` | `MovementRidge` (Charts.kt) | `activity_profile` | — (MET, model-free) |
| **Activity sessions / workouts** | `openActDetail` (session) | workouts section | workouts section | `activity` | AAD (web: Python · native: `ActivityModel`) |
| Steps / active calories / **distance** | activity report stats | activity day stats | activity day stats | `activity_daily` (incl. `distance_m`) | — |
| Previous days browser | `openDaysBrowser` → `openDayPage` | `AllDaysView` → `DayDetailView` | `AllDaysScreen` → `DayReportScreen` | day keys | — |
| Device & data health | `renderDevice` | device section | device section | `device`, `streams` | — |

## The day is one unit — pair night + activity by *wake date*

All three clients render **one "day" = last night's sleep + that day's activity**, drillable
into either half and browsable back through previous days. The hero on each home screen is
the most recent day; "show all N days" (web: `openDaysBrowser`; iOS: `AllDaysView`) opens
the rest, each as a combined night+activity detail.

The **pairing rule matters and must stay identical across clients**: nights are labelled by
their **onset** date (the evening you went to bed), so an overnight sleep that crosses
midnight belongs to the *next* day's morning. A day `D` pairs with the sleep you *woke from*
on the morning of `D` — the night whose **wake date** is `D`, not whose onset date is `D`.
This lives in `wakeYmd()` (web `app.js`), `Summary.wakeYmd` (iOS `Models.swift`) and
`Summary.wakeYmd` (Android `data/Models.kt`); keep the three in lockstep — the Android side has
JVM tests for it in `app/src/test/.../DayPairingTest.kt`. `nightForDay`/`night(forDay:)` pick the
longest in-bed night for a morning so a nap doesn't shadow the real sleep.

## Where the clients diverge

- **Home layout**: same day-unit model everywhere, but the two native clients use thomas.md
  Quiet Ink (warm paper, hairlines, serif titles) while the web still uses its own teal/card
  theme. Match *data/features*, not pixel-for-pixel layout. iOS opens details as sheets, Android
  as bottom sheets / full-screen destinations, the web as stacked `<dialog>`s. Android
  substitutes the platform serif and monospace families for New York and SF Mono, which do not
  exist there.
- **BLE sync**: both native clients sync **natively** — `RingSync.swift` (CoreBluetooth
  `BLETransport`) and `ble/RingSync.kt` (`BluetoothGatt` `BleTransport`) drive the Rust
  `RingSession` FFI (`oura-core`) to authenticate + drain into a writable DB. The web
  dashboard has **no** BLE; it reads a DB produced by the desktop `oura sync`. All of them
  ultimately run the SAME `oura-link` `OuraClient<T: Transport>` over a different transport
  (btleplug on desktop, CoreBluetooth-over-FFI on iOS, BluetoothGatt-over-FFI on Android).
  Ring 5 history payloads are coalesced into 32 KB chunks before crossing UniFFI;
  control/summary frames stay immediate, and diagnostics log only the aggregate frame/byte
  count rather than raw sensor payloads. That coalescing lives in the *client*, not in Rust,
  so `isHistoryPayload` exists in both Swift and Kotlin and must stay identical.

  Two structural differences on Android, neither optional: a `BluetoothGatt` permits exactly
  ONE outstanding operation, and enabling notifications requires writing the CCCD descriptor
  by hand rather than a single `setNotifyValue`. The four subscriptions are therefore queued
  strictly sequentially, preserving the invariant that the connect does not resolve — and so
  Rust does not start syncing — until every one is confirmed. Android also asks for a large
  MTU explicitly (`requestMtu(517)`), which CoreBluetooth negotiates on its own.

## Sleep metrics: three code paths, one algorithm — keep them in sync

The clinical sleep metrics (onset/REM latency, WASO, awakenings, cycles, fragmentation) and
sleep debt are computed **three times** and must stay identical: in Rust (`oura-summary`
`sleep_metrics` / `smooth_stages` / `count_bouts` / `count_periods` + `sleep_debt_summary`)
for the web, in Swift (`Reports.swift` `Sleep.metrics` / `Sleep.smooth` +
`Summary.stagedSleepDebt`) for iOS, and in Kotlin (`data/Sleep.kt` `Sleep.metrics` /
`Sleep.smooth` / `Sleep.bouts` / `Sleep.periods` + `Summary.stagedSleepDebt`) for Android.
The Kotlin copy is the one with unit tests (`SleepMetricsTest`, `SleepDebtTest`) — they run
headlessly, so they are the cheapest place to pin a definition before changing it anywhere. Sleep debt groups every sleep session by wake-date,
including naps in that day's total, then evaluates 14 calendar days with at least five
valid days; this matches the decompiled Android input and UI. The nightly **sleep need**
is personalized like Oura's (`SleepDebtInput.longTermSleepTimeAvgSeconds` ← the long-term
`sleepTimeAvg` baseline): each day's need is the mean of that user's daily totals over the
previous 90 days, IQR-outlier-filtered, clamped to 7–9 h, rounded to 15 min, causal (a
night never sets its own need), with an 8 h fallback below 14 valid history days — see
Rust `sleep_need_s` and its Swift mirror `needS(on:)` in `stagedSleepDebt`. The web reads it from the
summary JSON; iOS and Android recompute from the
**on-device** SleepNet hypnogram (`NightRow.stages`), because both run `build_summary` with
`NoModelRunner` (no server-side staging), so the FFI `stages_full`/`metrics` are empty there.
The raw signal series (`nights[].series`) DO come from the FFI everywhere. If you change the
smoothing window or a metric definition, change **all three** implementations.

**Autonomic-by-stage** (mean HR/HRV per sleep stage) is the same story: Rust
`autonomic_by_stage` fills `nights[].autonomic` for the web; iOS and Android recompute
(`Sleep.autonomic` in Swift and Kotlin) from their on-device hypnogram since that FFI field is
null under `NoModelRunner`. One deliberate difference: the web maps each HRV/HR sample to a
stage by its **true timestamp** (`hrv_event` gives `interval_min`-spaced samples), while the
native clients only have the even-spread downsampled `series`, so they align by **index
fraction** — the two can differ by a hair. We expose per-stage means (esp. deep-sleep HRV) rather than an overnight HRV "slope":
nocturnal HRV is stage-driven (deep ↑, REM ↓), so a slope tracks stage order, not recovery —
which is why Oura's own app has no per-night HRV trend either.

## Known gaps

### Web-only, not on the native clients

- **Advanced & debugging**: on-ring feature toggles (`/api/feature`) and the per-type
  event stream. Profile editing is native on iOS and Android, including optional health
  import for height and weight (plus date of birth and biological sex on iOS), plus optional
  export of workouts (add/remove as detections change), sleep stages, heart rate, HRV,
  resting HR, steps, calories, and distance.

### Android-specific divergences (deliberate, not bugs)

- **Typography**: iOS uses New York (system serif) and SF Mono. Neither exists on Android, so
  `ui/Theme.kt` takes the platform's `FontFamily.Serif` / `FontFamily.Monospace`. The palette
  hex values are shared verbatim with `Theme.swift`; only the type families differ.
- **HRV is written as RMSSD, not SDNN**: HealthKit has
  `heartRateVariabilitySDNN`; Health Connect only offers
  `HeartRateVariabilityRmssdRecord`. The `rmssd()` function already exported by `oura-core`
  is what feeds it, so the number is honest rather than a relabelled SDNN.
- **Partial profile import**: Health Connect has no date-of-birth or biological-sex record,
  so the Android importer can prefill only height and weight. Age and sex stay manual entry.
  `HealthProfileImporter` on iOS reads all four.
- **Sample de-duplication** uses Health Connect's `Metadata.clientRecordId` /
  `clientRecordVersion` instead of `HKMetadataKeySyncIdentifier` / `SyncVersion`. Same
  semantics — an upsert keyed by our own id — different spelling.

### The on-device model runtime

Both native clients build **LibTorch 2.9.0 with the lite interpreter from source** —
`apps/ios/spike/build_libtorch_ios.sh` and `apps/android/spike/build_libtorch_android.sh`.
Android does *not* use the published `org.pytorch:pytorch_android_lite`: the last Maven
release is 1.13.1 (2022), while `tools/export_mobile.py` exports against torch 2.9, and these
models are full TorchScript pipelines with preprocessing and data-dependent control flow baked
into the graph — exactly the things whose operator versions move. Building the same runtime is
what makes the two clients bit-exact on the same `.ptl` files rather than approximately equal.

Both runtimes and the `.ptl` files are gitignored local artifacts, so a fresh checkout builds
only the model-free flavor. On Android that flavor is `lite`; a `full` build without LibTorch
still compiles and runs, reporting the missing library as a model error rather than crashing.

Building LibTorch for Android off an x86_64 host needs a shim NDK, because CMake's Android
support neither finds the NDK's unified sysroot on such a host nor accepts a compiler
override. `apps/android/README.md` documents the whole arrangement; the part worth knowing
here is that the clang resource directory must be a *merge* of the host compiler's headers
and the NDK's runtime libraries — Google's clang is a fork whose `arm_neon.h` calls builtins
upstream clang lacks, while a distro clang ships no compiler-rt or libunwind for Android.

### Where Android does better than iOS

- **Background sync**: iOS has no unrestricted background CPU, so `IdleTimerLock` merely keeps
  the foreground app awake and reasserts itself across lifecycle transitions. Android holds a
  real reference-counted `PARTIAL_WAKE_LOCK` (`ble/WakeLockOwner.kt`, same `"ring-sync"` /
  `"pair-screen"` / `"models"` owner keys) plus a `connectedDevice` foreground service, so a
  long history drain survives the app going to the background — which is what the official
  Android client does too.
- **Crash forensics**: iOS infers a low-memory kill from a leftover session log and subscribes
  to MetricKit. Android reads `ActivityManager.getHistoricalProcessExitReasons`, which reports
  the reason (LOW_MEMORY / ANR / native crash) directly.
- **Polysomnograph crosshair**: web has a hover crosshair; iOS uses a touch scrubber
  (drag across the lanes) — same idea, adapted to the input.
- **DNA explorer** (`/dna`): reads genome `*.vcf.gz` files and scores single-SNP **traits**
  against the editable `dna/catalog.json`, plus **polygenic scores** — the illustrative
  built-ins in the catalog *and* real [PGS Catalog](https://www.pgscatalog.org/) scoring
  files (`dna/scores/*.txt.gz`). Parsing/scoring is the `crates/oura-dna` crate
  (`vcf`/`catalog`/`pgs`/`score` modules); the server glue is `crates/oura-cli/src/dna.rs`
  → `dashboard/web/dna.{html,js,css}`. A genome + which scores to apply are chosen with
  selectors; a PGS ID can be fetched on demand (`POST /api/dna/fetch` → EBI) into
  `dna/scores/`. Genomes are read from a **configurable directory** — keep your large,
  private files anywhere via `oura dashboard --dna-files <dir>` (or `$OURA_DNA_FILES`);
  it defaults to the repo's `dna/files/`, while the catalog + fetched PGS scores always
  live in the repo `dna/`. PGS scoring is strict: effect+other-allele matching, strand-flip
  resolution, palindromic-ambiguous exclusion, `weight_type` (OR/HR → `ln`), and coverage
  stats — a raw sum is reported honestly (no population reference is shipped, so no
  percentile). Trait interpretation is **strand-aware** too (reverse-complement fallback for
  non-palindromic SNPs), since a GRCh38 VCF stores e.g. `rs4988235` as A/G while catalogs
  write the classic C/T. **Deliberately web-only** — it has nothing to do with ring data, so
  it does not go through `oura-summary` and is not mirrored on iOS. If it's ever wanted on
  iOS, the `oura-dna` crate is the reusable brain.

  *Whole-genome (gVCF) support:* the reader handles 30x WGS **genomic VCFs** — most of the
  genome is stored as `END=` **reference blocks**, so a single streaming pass resolves any
  trait/PGS locus inside a hom-ref block as homozygous-reference (a per-chromosome merge-join
  cursor). Without this, coverage would collapse to only the sites where the sample carries a
  variant. One 298 MB / 30x gVCF parses in ~6 s (then cached); a `pos_set` gate lets the
  ~tens-of-millions of non-target records skip all lookups. A `.snp-indel` file is the one to
  use — `list_files` classifies each `*.vcf.gz` (`snp-indel` vs `cnv`/`sv`) so the UI prefers
  the scoreable one and explains the copy-number / structural-variant files instead of
  scoring them to noise.

  *Network note:* this is the **only** outbound request in the whole app. It fetches
  **public** PGS score *definitions* on explicit user action; the genome never leaves the
  machine.

- **Blood panel** (`/blood`): tracks lab-test markers over time, reads each against its
  reference range, and surfaces the ones worth attention with plain-language advice. The
  compute — status (in/out of range), trend across draws, which side is "concerning" per
  marker, and the attention list — is real and lives in `crates/oura-cli/src/blood.rs`;
  the front-end is `dashboard/web/blood.{html,js,css}` (each marker card is a
  reference-band sparkline in the main dashboard's graph idiom, with a full time-series +
  advice in the detail dialog). **Currently the *inputs* are mocked** — a real SYNLAB draw
  series, hand-transcribed — so import/extraction is not yet wired. The planned shape:
  `import` parses an uploaded lab PDF locally, **dedupes by content hash** (re-importing the
  same file is a no-op), and caches to a small local **SQLite `blood.db`, separate from the
  ring's `oura.db`**. **Deliberately web-only** — like the DNA explorer it has nothing to do
  with ring data, does not go through `oura-summary`, and is not mirrored on iOS. When
  extraction is built, `blood.rs`'s marker model is the reusable brain.

When you close one of these gaps, update this section.

## Ring clock resets → epoch-aware time mapping (all three code paths)

`ring_timestamp` (ds) is a **per-boot relative deciseconds counter**: it resets to ~0
every time the ring reboots (battery drain, firmware reset). Naively anchoring every ds
to one global `max_ds`/`captured_unix` scatters older boots to wildly wrong dates (a boot
can land months in the past). The fix segments events into boot **epochs** — walk in real
sync order `(captured_unix, then insertion id)`, split on any large backward jump in ds, then use
the epoch's on-ring `time_sync` (`ring_timestamp` ↔ UTC) records as authoritative anchors.
`captured_unix` is only an epoch-selection hint and a fallback for legacy data. This
lives in **three places that must stay in sync**:

- `crates/oura-summary/src/ring_time.rs` — the shared `RingClock`; fixes night/activity/
  movement **dates for both clients** at once.
- `tools/epoch_time.py` (helper) used by `tools/run_activity_model.py` and
  `tools/run_sleep_model.py` — the **web** on-model session/hypnogram times.
- `apps/ios/OuraApp/EventStore.swift` (`epochs` / `unixSeconds`) used by
  `ActivityModel.swift` and `SleepStaging.swift` — the **iOS** on-device model times.
  iOS must be rebuilt to pick this up.
- `apps/android/app/src/main/java/md/thomas/openoura/data/EventStore.kt` (`RingClock`) — the
  **Android** on-device model times, a direct port of the Swift one.

## Premature sleep ends → evidence-based model windows

The ring can close a raw `bedtime_period` during a brief awakening even though sleep
continues. `oura-summary::normalize_bed_periods` repairs the model boundary in two stages:

- explicit sleep-only ACM, temperature, and SpO₂ packets can extend a raw end by up to
  three hours;
- when a long sleep already has at least 30 minutes of that explicit premature-end
  evidence, continuous accepted HR/IBI bursts may carry the candidate window farther.

Pulse evidence is deliberately gated: each burst needs multiple firmware-accepted heart
rate estimates, consecutive bursts can be at most 15 minutes apart, and naps or clean
bedtime ends never use daytime pulse sampling. The resulting canonical `start_ds/end_ds`
is passed unchanged to the Python SleepNet runner and iOS `SleepStaging`, so both clients
score the same recovered window. Regression tests include isolated daytime HR, long gaps,
periodic post-nap sampling, and the extracted Ring 5 brief-wake vector.

The polysomnograph's skin-temperature lane uses only `sleep_temp_event`. Generic
`temp_event` contains multiple device/ambient channels and must never be flattened into
the nocturnal skin-temperature series. `nights[].series.temp_span` records the actual
coverage inside an extended sleep window, so iOS and web leave a visible gap after the
last trustworthy sample instead of stretching or inventing a temperature collapse.

## Ring 5 extended history sync

Ring 5's `ExtGetEvent` batches are self-completing. Do not send the legacy `GetEvent`
ACK (`0x10`) afterward: the ring answers that ACK with another history burst, whose late
notifications race with the next data flush and are discarded. Extended summary result
code `0xff` is a rejected cursor, not a successful empty batch. `oura-link` now rejects
that result explicitly, and `oura-core` checkpoints zero and performs one deduplicated
recovery drain when an existing iOS database contains such a stale cursor.

A from-zero recovery may replay an older boot after the newer boot is already stored.
If that makes the selected epoch project an event more than six hours beyond its phone
capture time, all three implementations fall back to the newest globally plausible
`time_sync` projection. This prevents replay fragments from fabricating future days.

Incremental pulls key off `sync_state.next_cursor` (deciseconds). After a reboot the
ring's ds restarts low, so an empty incremental fetch verifies that the event immediately
before the saved cursor still exists. If that marker is absent, the native iOS core
checkpoints cursor 0 and drains the new boot epoch automatically. This also recovers
cursors poisoned by the pre-`d409f9e` extended-envelope timestamp decoder.
The link layer also rejects any single-batch cursor jump beyond 180 days. A physical
Ring 5 validation exposed malformed tail envelopes with near-`u32::MAX` timestamps;
discarding those impossible records prevents a new poisoned cursor while preserving
the surrounding valid events and terminal summary.

## Notes from the decompiled official Android client

These are observations about **Oura's own** Android app, kept because they explain why the
shared code behaves the way it does. Not to be confused with `apps/android/`, which is ours.

The official client uses SweetBlue's reference-counted `PARTIAL_WAKE_LOCK` during BLE work.
iOS has no equivalent unrestricted CPU wake lock, so `IdleTimerLock` keeps the foreground app
awake with the same reference-count ownership semantics and reasserts the idle-timer flag
after lifecycle transitions. Our Android client can and does hold the real lock — see
`ble/WakeLockOwner.kt`.

Its legacy NSSA path passes the ring's `BedtimePeriodValue` directly to the
sleep-stage handler. Its newer feature-gated stateless bedtime detector instead skips
ring bedtime events and derives periods from feature-session, state-change, motion,
temperature, time-sync, and alert events at one-minute resolution. That detector's
dynamically delivered model is not embedded in their APK. The shared summary therefore
keeps the raw ring bounds alongside locally adjusted bounds, and only adjusts an end
when adjacent bedtime segments or sleep-only sensor evidence support it.
