# Two clients, one core — keep them in sync

open_health has **two user-facing clients that render the same health data**. When you
add or change a feature, you almost always have to touch **both**. This is the map.

| | Web dashboard | Native iOS app |
| --- | --- | --- |
| Where | `dashboard/web/` (vanilla HTML/CSS/JS) served by `crates/oura-cli/src/dashboard.rs` | `apps/ios/OuraApp/` (SwiftUI) on `crates/oura-core` (UniFFI) |
| Entry | `oura dashboard` → `http://127.0.0.1:8090` | `apps/ios/OuraApp/build_run.sh` (model-free) / `build_run_torch.sh` (on-device models) |
| Render code | `app.js`, `styles.css`, `index.html` | `OuraApp.swift`, `Theme.swift` |
| Models run via | Python torch runners (`tools/run_*_model.py`) | sleep staging in Rust (`SleepStaging.swift` calls `oura-core`); activity, illness and CVA run as on-device `.ptl` (`TorchBridge.{h,mm}` + `ActivityModel`/`IllnessModel`/`CvaModel.swift`) |

## The one shared brain: `crates/oura-summary`

`oura_summary::build_summary()` computes **the summary JSON both clients render** — vitals,
per-night stats, the digest, the MET activity profile, steps/kcal, device health. The web
calls it in `dashboard.rs`; iOS calls it through `oura-core`'s `summary_json()` FFI. The
models are injected via the `ModelRunner` trait (web: `PythonRunner`; iOS: `NoModelRunner`
+ the on-device torch code).

The non-model math is the **ported ecore ground truth** from `crates/oura-analysis`
(`ported::{spo2, temperature, metabolic, baseline}`): SpO₂ calibration, nightly skin
temperature, Schofield BMR (→ `total_kcal`), Jackson VO₂max, steps→distance, and the
annealing-EMA personal baseline behind each vital's `delta_pct`. Add a new derived
metric there once and both clients receive it in the JSON.

**So the rule of thumb:**

- **A new computed metric / field** → add it once in `oura-summary` (`build_summary`). Both
  clients receive it in the JSON. Then render it in **both** `app.js` and `OuraApp.swift`.
- **A new visualization / UI** (no new data) → do it in **both** `app.js` and `OuraApp.swift`.
- **A new model** → wire **both** runners: a `tools/run_*_model.py` (used by `PythonRunner`)
  **and** an `oura_*` function in `TorchBridge.mm` + a Swift `*Model.swift` that builds the
  same input tensors and folds the result into the summary.

## Feature ↔ feature correspondence

| Feature | Web (`app.js`) | iOS (`OuraApp.swift`) | Data (JSON key) | Model |
| --- | --- | --- | --- | --- |
| Digest headline | `load()` digest | `RootView` digest | `digest` | — |
| Vitals (HRV/RHR/temp/SpO₂) | `renderTiles` / `VitalCell`-like | `VitalCell` | `vitals`, `nights[]` | — |
| **Unified day (night + activity)** | `renderDay`, `dayCard` | `TodayCard` | `nights[]`, `activity*` | — |
| **Full-page sleep report** (polysomnograph + clinical metrics + interpretation) | `openDayPage`→`sleepSection` (`tlBox` lanes from `nights[].series_t`, `hypnoSvg`) | `DayReportView`→`SleepReport`, `Polysomnograph` (Reports.swift) | `nights[].{stages_full,series,metrics}` | SleepNet |
| **Sleep debt** (14-day card + cumulative debt / total sleep detail) | `renderSleepDebt`→`openSleepDebt` | `SleepDebtCard`→`SleepDebtDetail` | `sleep_debt`, grouped by wake date including naps | SleepNet |
| **Day JSON export** (iOS: the open tab's section; web: the whole day — night + debt, daily stats + MET profile + workouts, and the heart-rate slots) | `openDayPage` "Export JSON" → `exportDayJson` (download) | `DayReportView` export menu → `DayExport` (copy / share sheet) | same sections as the report | — |
| **Research export** (raw CSVs for a time window: every beat, 30 s movement, SpO2 ratio, skin temperature, on the corrected clock; README + manifest in the ZIP) | "Research export" panel → `GET /api/research-export?start&end&streams&tz` | Help & diagnostics → Research export → `ResearchExportView` (share sheet) | `oura_summary::research_export` (`build` + `to_zip`), also `oura research-export` | — |
| **Full-page activity report** (24h MET profile + intensity metrics) | `openDayPage`→`activitySection`, `movementSvg` | `DayReportView`→`ActivityReport`, `MetProfile` (Reports.swift) | `activity_profile`, `activity_daily`, `activity` | AAD |
| **Heart rate across the day** (per-slot 5th–95th band + median tick; beats vs 5-min averages) | `openDayPage`→`heartSection`, `hrTimelineSvg` (`GET /api/hourly-hr?minutes=`; 15 min default, 1 h switch) | `HeartRate.swift` (`HourlyHR`, hourly) | `oura-summary::hourly_hr::{hr_bins, hourly_hr}` (not in the summary JSON) | — |
| Stage breakdown | `stageBar` | `StageBreakdown` | `nights[].{deep,light,rem,wake}_pct` | SleepNet |
| **Autonomic recovery by stage** (mean HR/HRV in deep/light/REM) | `sleepSection` autonomic grid | `SleepReport` `autonomicGrid` | `nights[].autonomic` | SleepNet (needs hypnogram) |
| **Cardiovascular age** | `renderCardio` | Cardio section | `cardio` | CVA (web: Python · iOS: `CvaModel`) |
| **VO₂max estimate** | `renderCardio` | Fitness section | `fitness.vo2max` | — (Jackson, model-free) |
| Movement ridge | `ridgeSvg` | `MovementRidge` | `activity_profile` | — (MET, model-free) |
| **Activity sessions / workouts** | `openActDetail` (session) | workouts section | `activity` | AAD (web: Python · iOS: `ActivityModel`) |
| Steps / active calories / **distance** | activity report stats | activity day stats | `activity_daily` (incl. `distance_m`) | — |
| Readiness (ported `readiness_calculate`, baseline carried night to night), breathing rate (ported from IBI) | `scores.readiness` | `scores.readiness` | `nights[].oura_readiness`, `breath_rate`, `breath_rate_port` | no contributor display yet; rest mode not wired (rest-mode ring events are not stored) |
| Ideal sleep midpoint (sleep score timing) | profile dialog, `f-midpoint` | `ProfileSettingsView` | `profile.ideal_midpoint`, `profile.json` `chronotype` | — |
| **Sleep stager choice** (official NSSA staging, built-in tree-ensemble staging, or automatic; an option whose model files are missing is disabled with a notice) | profile dialog, `f-stager` (`renderStagerChoice`); `oura dashboard --sleep-stager` | `ProfileSettingsView` `sleepStagingCard` (`SleepStagerStatus`) | `sleep_stager` (`choice`, `effective`, `options[]`), `profile.json` `sleep_stager`; resolved once in `oura_summary::sleep_stager` | NSSA (`sleepstaging_2_6_0` + extracted classifier) or the built-in stager |
| Activity score + contributors (ported `actinfo` and activity score) | `activitySection` | `ActivityReport` | `activity_daily` (`score`, `contributors`, `class_min`) | — |
| **Daily scores and contributors** (readiness 9, sleep 7, activity 6 sub-scores; band colors; history) | — | `TodayTab` contributors, `ScoreDetailView`, `Heatmap` (`Home.swift`, `Detail.swift`, `Viz.swift`) | `scores`, `nights[].{oura_readiness,oura_sleep_score}.contributors`, `activity_daily[].contributors` | ported daily scorer |
| **Vitals tiles and metric history** (value, change vs 14-day mean, series; scrubbable chart, daily table) | — | `VitalsTab`, `MetricDetailView` | `nights[]`, `vitals`, `activity_daily`, `cardio`, `fitness` | — |
| **Trends** (period scores, contributor heatmap, body averages) | — | `TrendsTab`, `ScoreTrendCard` | same | — |
| Previous days browser | `openDaysBrowser` → `openDayPage` | `HistoryView` (table of scores, sleep, steps; a row selects the day on Today/Vitals) | day keys | — |
| **Live heart rate** (start, plot beats, average / low / high / RMSSD) | `POST /api/live-hr` panel | `LiveHeartRateCard` (`LiveHR.swift`) → `RingSession.live_heart_rate` (FFI) → `OuraClient::live_heart_rate` | — (not stored) | — |
| **Symptom radar history** (4 biomarkers over 14-90 days against the personal range) | — (flagged biomarkers only) | `RadarDetailView`, `RadarCard` | `symptoms` / `illness`, `nights[]` | Radar |
| **Sleep debt history** (debt and sleep series, daily table) | `openSleepDebt` | `DebtDetailView` | `sleep_debt` | SleepNet |
| Device & data health (opened from the top-bar ring button, whose border is the battery gauge) | `renderDevice` in `#device-dialog` | `RingBatteryButton` → `SyncView` ("Your ring") | `device`, `streams` | — |
| **Battery history** (level over the days with readings; charging runs drawn apart) | `renderDevice`→`batteryChart` | — | `device.battery_history` (`[unix, percent]`, 14 days) | — |

## The day is one unit — pair night + activity by *wake date*

Both clients render **one "day" = last night's sleep + that day's activity**, drillable
into either half and browsable back through previous days. The hero on each home screen is
the most recent day; "show all N days" (web: `openDaysBrowser`; iOS: the calendar button, `HistoryView`) opens
the rest. iOS swipes between days on Today and Vitals (`DayPages`).

The **pairing rule matters and must stay identical across clients**: nights are labelled by
their **onset** date (the evening you went to bed), so an overnight sleep that crosses
midnight belongs to the *next* day's morning. A day `D` pairs with the sleep you *woke from*
on the morning of `D` — the night whose **wake date** is `D`, not whose onset date is `D`.
This lives in `wakeYmd()` (web `app.js`) and `Summary.wakeYmd` (iOS `Models.swift`); keep the
two in lockstep. `nightForDay`/`night(forDay:)` pick the longest in-bed night for a morning so
a nap doesn't shadow the real sleep.

## Where the two clients diverge

- **Automatic sleep analysis (iOS)**: opening or syncing the app reuses saved sleep
  results and analyzes only the latest night when its result is missing. A changed
  bedtime window counts as missing. Older missing nights require “Refresh analysis”
  in their Sleep tab. Automatic runs do not prune the historical model cache.
- **iOS compact disclosures**: symptom radar initially shows its status and explanation;
  “View details” reveals measurements and personal ranges together. Ring troubleshooting
  is a "Help & diagnostics" card of grouped rows (check data, share report, export raw
  data, technical reports on their own page) with the reset kept apart as a destructive row.
  These phone-layout changes are intentionally iOS-only; the underlying health data is unchanged.
- **Manual analysis refresh (iOS)**: each day's Sleep and Activity tabs can rerun their
  respective model from saved ring data. Sleep uses the displayed night's bedtime window
  (paired by wake date); activity uses the selected calendar day. The action bypasses
  that result's cache, preserves other days, and publishes successful results to the open
  report and summary cache. This is separate from syncing new data from the ring.
- **Raw ring data export (iOS)**: Help & diagnostics → “Export raw ring data” writes a
  self-contained copy of the phone's SQLite store (`VACUUM INTO`, no auth key) and hands
  it to the share sheet. On a computer it is a normal `oura --db <file> …` input, so any
  on-phone analysis can be reproduced exactly (`oura --db exported.db dashboard --tz-offset 2`).
- **Ring clock sanity (all three twins)**: two anchors of one boot must agree on the
  counter rate. A counter that *stalled* between them (ring off; wall clock ran ahead)
  takes the later anchor's offset from the stall on, using the download time to pick the
  side. A counter that ran *faster* than wall time (a fresh ring's erratic first days,
  weeks of ds in an hour) makes everything between the two anchors **undated**: the
  summary, the Python runners and the iOS models all leave that data out instead of
  scattering it over months of phantom days.
- **On-device model caches (iOS)**: every cache file carries a store digest (row count,
  last id, anchor count, last anchor id). When it matches, activity and illness return
  their cached results without streaming the store; illness only scans the tags it
  uses; CVA runs at most once per local day (vascular age moves on a scale of months and
  every sync adds PPG segments). Activity days the model rejects are cached as failed
  under their input fingerprint and skipped until a forced refresh or a pipeline bump.
- **Ring clock diagnostics**: the summary JSON carries a `clock` block (per-boot ds range,
  sync window, anchor count/sources, `undated_nights`, `warnings`) and each night carries
  `wake_ymd`, `start_unix`, `end_unix`, `clock_source`. iOS renders the warnings on Home,
  the per-boot table under Technical reports, and appends it to the shared diagnostic report.
- **Home layout**: same day-unit model on both, but iOS uses thomas.md Quiet Ink (warm paper,
  hairlines, serif titles) while the web still uses its own teal/card theme. Match *data/features*,
  not pixel-for-pixel layout. iOS opens details as sheets; the web as stacked `<dialog>`s.
- **BLE sync**: iOS syncs **natively** — `RingSync.swift` (CoreBluetooth `BLETransport`)
  drives the Rust `RingSession` FFI (`oura-core`) to authenticate + drain into a writable
  DB. The web dashboard has **no** BLE; it reads a DB produced by the desktop `oura sync`.
  Both ultimately run the SAME `oura-link` `OuraClient<T: Transport>` over a different
  transport (btleplug on desktop, CoreBluetooth-over-FFI on iOS). Ring 5 history payloads
  are coalesced into 32 KB chunks before crossing UniFFI; control/summary frames stay
  immediate, and diagnostics log only the aggregate frame/byte count rather than raw
  sensor payloads. This mirrors Android's `ExtGetEvent` raw-buffer accumulation without
  sacrificing the Rust client's 4,096-event cursor checkpoints.

## Sleep metrics: two code paths, one algorithm — keep them in sync

The clinical sleep metrics (onset/REM latency, WASO, awakenings, cycles, fragmentation) and
sleep debt are computed in Rust (`oura-summary` `sleep_metrics` / `smooth_stages` /
`count_bouts` / `count_periods` + `sleep_debt_summary`) for the web and mirrored in Swift
(`Reports.swift` `Sleep.metrics` / `Sleep.smooth`) for iOS. Sleep debt is Rust only: iOS
writes its on-device hypnograms to the staged sidecar and reads the rebuilt summary. The
debt algorithm itself is open_oura's `sleep_debt`. Sleep debt groups every sleep session by wake-date,
including naps in that day's total, then evaluates 14 calendar days with at least five
valid days; this matches the decompiled Android input and UI. The nightly **sleep need**
is personalized like Oura's (`SleepDebtInput.longTermSleepTimeAvgSeconds` ← the long-term
`sleepTimeAvg` baseline): each day's need is the mean of that user's daily totals over the
previous 90 days, IQR-outlier-filtered and clamped to 7–9 h, weighted by days/90 against a
7.4 h prior (one wearer's need as reported by the Oura app was 7.3 to 7.4 h). A day with fewer than 14 valid days before it uses all of the
user's valid days, and the prior alone applies below 14 valid days in total. A `sleep_need_h`
in `profile.json` (4 to 12 h) replaces the estimate; iOS sets it under Profile > Sleep and shows
the reason and the days the estimate moved (`sleep_debt.need_note`, `need_changes`) on the Sleep
debt screen. The web does not show these yet (Known gaps). See
Rust `sleep_need_s`. Both clients read it from the summary JSON. iOS stages sleep from the
**on-device** SleepNet hypnogram (`NightRow.stages`), because iOS runs `build_summary` with
`NoModelRunner` (no server-side staging), so the FFI `stages_full`/`metrics` are empty there.
The raw signal series (`nights[].series`) DO come from the FFI on both. If you change the
smoothing window or a metric definition, change **both** implementations. Oura's own stagings
(`staging_source` `nssa` or `ring`) are never smoothed or deep-refined (`is_oura_staging` /
`Sleep.isOuraStaging`); only the signal-derived estimate is. Both clients also draw
`stages_5min`, the official app's 5-minute chart (`aggregate_30s_to_5min` / `Sleep.aggregate5Min`),
for whichever stager ran. Only an NSSA night carries the "Oura app" label on that lane.

**Sleep stager choice.** `oura_summary::sleep_stager` is the single place that resolves it.
`profile.json` holds `"sleep_stager": "official" | "xgb"` (absent means automatic). The official
stager is Oura's `sleepstaging_2_6_0` graph plus its extracted classifier
`sleepstaging_2_6_0_classifier.bin`. Both files are gitignored model files, so a build can lack
them. The built-in stager (`xgb`) is open_oura's Rust pipeline with a tree ensemble trained
privately by the author, compiled in, and always available. Automatic picks official when its
files are present, otherwise built-in. Each client reports which files it found
(`register_official_files`; web: the models directory or `$OURA_MODELS_DIR`, iOS: the app bundle
through `set_official_sleep_stager_files`), and the summary's `sleep_stager` object carries the
choice, the stager in use and a notice per unavailable option. iOS keeps one staging cache file per
stager; the sidecar `staged_hypnograms.json` carries each night's `source` so the brain treats
NSSA nights verbatim (`is_oura_staging`) and built-in nights as before.

**Autonomic-by-stage** (mean HR/HRV per sleep stage) is the same story: Rust
`autonomic_by_stage` fills `nights[].autonomic` for the web; iOS recomputes in Swift
(`Sleep.autonomic`) from its on-device hypnogram since that FFI field is null under
`NoModelRunner`. One deliberate difference: the web maps each HRV/HR sample to a stage by its
**true timestamp** (`hrv_event` gives `interval_min`-spaced samples), while iOS only has the
even-spread downsampled `series`, so it aligns by **index fraction** — the two can differ by a
hair. We expose per-stage means (esp. deep-sleep HRV) rather than an overnight HRV "slope":
nocturnal HRV is stage-driven (deep ↑, REM ↓), so a slope tracks stage order, not recovery —
which is why Oura's own app has no per-night HRV trend either.

## Known gaps (iOS-only, not yet on the web)

- **VO2 max from 6-minute walks** (iOS, `WalkMath.swift`, `WalkTest.swift`, `Vo2Views.swift`):
  walking or running started under Activities records a GPS route (`routes/<id>.json` beside the
  database, while the exercise runs only). Walks the ring detected use the phone's step counter
  distance for the best six minutes. A window of at least 480 m, with the median of the ring's
  per-minute heart rate over its last 70 s, goes to `vo2max_walk_6min` (open_oura
  `vo2max_ukk_6min`) and is kept in `vo2.json`. The VO2 max tile shows the latest reading, and its
  detail screen charts them against the age, sex and weight formula. The web has no location or
  step counter source and still shows the formula value alone.
- **Sleep need setting and explanation** (iOS, `ProfileSettings.swift`, `Detail.swift`): the
  Profile Sleep card sets `sleep_need_h`, and the Sleep debt screen shows why the estimated need
  is what it is and when it moved. The web reads the same summary fields but shows neither.
- **Capture hints** (iOS, `CaptureNeeds.swift`): tiles without data from a ring capture feature
  dim and point to Profile > Ring capture, and Exercise heart rate stays locked until Step motion
  is applied. The web has no ring link, so its panels keep their text hints.
- **Today / Vitals / Trends tabs** (iOS, `Home.swift`): the home is three tabs over the same summary.
  Today shows one day (day strip, three scores, the selected score's contributors, sleep,
  activity, body). Vitals is a tile per metric. Trends covers 14, 30 or 90 days with a
  contributor heatmap. A score opens `ScoreDetailView`, a metric opens `MetricDetailView`,
  and a day in either opens the day report. The web dashboard still has its single-page home
  and does not render contributors.

- **Ring capture settings** (iOS, `CaptureSettings.swift`, in the Profile sheet): reads the ring's
  capture mode for daytime HR, exercise HR, SpO2, resting HR and two unnamed features
  (`RingSession.capture_settings`) and sets them off or automatic
  (`apply_capture_settings`). The web dashboard has no ring link for this.

Now on both: the model-free Symptom Radar (`symptoms`, used when the Python runner
has no `illness`) and the ring-clock warnings (`clock.warnings`). Still iOS-only:

- **On-phone ring sync UX**: the ring's own battery and firmware are read right after
  authentication (`SyncProgressListener.on_device`) and shown at once (`RingInfo`,
  `ringCard`, battery button). Sync continues in the background, reconnects to the saved
  ring by identifier, registers the app stream (`16 01 02`) on every ring so it asks for a
  15 ms connection interval (a Gen 3 batch arrives in ~420 ms instead of ~850 ms; the mode
  lasts one connection), and a paired ring shows a status card with the key collapsed. The web
  dashboard reads a local database and has no BLE sync.
- **Sleep staging on desktop**: the web dashboard stages with the same two stagers as iOS (the
  NSSA runner `tools/run_sleep_model.py`, or the built-in Rust stager in
  `oura_summary::sleep_stager::stage_nights_xgb`, cached in `xgb_stage_cache.json`). The
  official stager needs Python with torch and the model files; if the runner returns nothing the
  built-in stager runs, and nights it cannot stage fall back to the signal estimate. With
  `steps_source = model`, desktop has no step counter weights loader and falls back to the
  ring's step count.
- **Official stager coverage**: on the web the official stager stages every night (about 60 s for a
  full database, cached in `nssa_cache.json`). iOS stages only the latest night automatically
  with it, as the built-in stager covers every night; older nights are staged on demand or by
  "Recompute everything". Switching the stager on iOS re-stages from that stager's own cache.
- **Third stager**: there are two stagers, not three. The Rust port cannot load the extracted NSSA
  classifier (a different forest format), so "NSSA features with the vendor classifier in Rust"
  does not exist; the official stager always runs the vendor graph.
- **Sleep report without a hypnogram**: iOS still draws the time-in-bed strip and the
  signal lanes; the web returns early.
- **Sleep score + breathing rate** (`nights[].sleep_score`, `breath_rate`).
- **Skin temperature / latest HR vitals and trend pages**, **hourly heart rate**
  (`hourly_hr` is FFI-only; no `/api` endpoint yet).
- **Swipeable home day**: the iOS home pages through days with a horizontal swipe, and the
  vitals and sleep debt follow the selected day (`homeDay` in `OuraApp.swift`); the web home
  shows the latest day. A dashed "now" line marks the current time on today's movement chart
  (`MovementRidge`, `MetProfile`); the web movement chart has none.
- **Symptom Radar details**: all four biomarkers with their personal band
  (`lower`/`upper`); the web lists only the flagged ones.

## Known gaps (web-only, not yet on iOS)

- **One-page day view**: web shows Sleep, Activity and Heart rate on one scrolling page, every
  chart on one time axis (`dayAxis`) with a shared cursor (`dayCursor`), plus ‹ › / ← → to step
  through days with data; iOS `DayReportView` keeps tabs and reaches days via `HistoryView`.
- **Time-true overnight lanes**: web draws the polysomnograph lanes from `nights[].series_t`
  (`[unix, value]` points, gaps kept). iOS still spreads `nights[].series` evenly over the
  night, which mis-times a lane whose stream stops early (the 5-min HR averages end at wake).
- **15-minute heart-rate slots**: the web Heart rate tab defaults to 15-minute bars
  (`hr_bins`, with a 15 min / 1 h switch); iOS `HeartRate.swift` still shows hourly bars.
- **Live heart rate**: now on both. The web streams beats from `oura live-hr` over
  `POST /api/live-hr`; iOS runs the same `OuraClient::live_heart_rate` through the FFI and does
  not store the beats (the CLI writes `heart_rate_live` readings).

- **Advanced & debugging**: on-ring feature toggles (`/api/feature`) and the per-type
  event stream. Profile editing is now native on iOS, including optional Apple Health
  import for date of birth, biological sex, height, and weight, plus optional export
  of workouts (add/remove as detections change), sleep stages, heart rate, HRV,
  resting HR, steps, calories, and distance.
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
the epoch's on-ring `time_sync` (0x42) and `rtc_beacon` (0x85)
(`ring_timestamp` ↔ UTC) records as authoritative anchors. RTC beacons must also
retain their JSON in the iOS metadata reader. Ignoring them can shift a whole
night to its download time or project a new boot through an older boot's clock.
`captured_unix` is only an epoch-selection hint and a fallback for legacy data. Every event
resolves with a **source**: `anchor` (its own boot's time_sync/rtc_beacon/phone anchor),
`projected` (another boot's anchor, only when this ds continues that boot's counter — a
rebooted ring restarts near zero and must never be projected through an older boot that
only ran at higher counts), `download_time` (capture-time arithmetic, allowed only for a
boot drained sync after sync so the error is bounded by one sync gap) or `undated` (a boot
downloaded in one go with no anchor). Nights whose bounds are not `anchor`/`projected` are
**withheld** from `nights` and listed in `clock.undated_nights` — showing them dated to the
download would put a 23:00→08:00 sleep at 07:00→15:00 on the wrong day. To make anchors
exist for every boot, the iOS sync (`oura-core` `sync_inner`) now sends the phone clock to
the ring (`sync_time_app`, which makes the ring log a `time_sync`) and, after a drain that saw
new ring time, records a **phone anchor** pairing the newest drained ds with the phone clock.
Phone anchors live in the `phone_anchors` table (`ring_timestamp`, `unix_time`,
`captured_unix`), not in `events`: the ring never sent them, and anything that replays,
exports or counts `events` must not see them.
The view `events_with_anchors` unions `events` with the anchors as `time_sync` rows
(`{"unix_time":..,"source":"phone"}`) in the `(captured_unix, id)` order the clock needs;
every reader that builds a `RingClock` reads that relation (`Store::decoded_events`,
`clock_events_relation`, `clock_rows`, `EventStore.relation`, `_common.clock_events_relation`),
and falls back to `events` on a database that never had the table. Earlier builds wrote the
anchors into `events` (tag 0x42, body = unix LE + "phone"); `Store::open` and
`migrate_if_writable` move those rows once (`store_meta.phone_anchors_migrated`).

`sync_time_app` sends `12 09 <u64 unix s> <tz half hours>`. Builds
before this change sent `<token> <unix/256>` and set the clock early or late by up to 255 s;
Details: open_oura `docs/sync-orchestration.md`.

The clock logic lives in **three places that must stay in sync**:

- `crates/oura-summary/src/ring_time.rs` — the shared `RingClock`; fixes night/activity/
  movement **dates for both clients** at once.
- `tools/epoch_time.py` (helper) used by `tools/run_activity_model.py` and
  `tools/run_sleep_model.py` — the **web** on-model session/hypnogram times.
- `apps/ios/OuraApp/EventStore.swift` (`epochs` / `unixSeconds`) used by
  `ActivityModel.swift` and `SleepStaging.swift` — the **iOS** on-device model times.
  iOS must be rebuilt to pick this up.

## Premature sleep ends → evidence-based model windows

The ring can close a raw `bedtime_period` during a brief awakening even though sleep
continues. `oura-summary::normalize_bed_periods` repairs the model boundary in two stages:

- explicit sleep-only ACM, temperature, and SpO₂ packets can extend a raw end by up to
  three hours, but only while they keep coming: the extension walks them in time order
  and stops at the first silence over 30 minutes (`MAX_SLEEP_SUPPORT_GAP_DS`). A Ring 4
  reports no `sleep_state`, so without this a 20-minute still spell 2.5 hours after
  waking — resting SpO₂/temperature packets — was joined onto the night (a 09:03 wake
  shown as 11:51);
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

## Android parity notes

The decompiled Android client uses SweetBlue's reference-counted
`PARTIAL_WAKE_LOCK` during BLE work. iOS has no equivalent unrestricted CPU wake
lock, so `IdleTimerLock` keeps the foreground app awake with the same reference-count
ownership semantics and reasserts the idle-timer flag after lifecycle transitions.

Android's legacy NSSA path passes the ring's `BedtimePeriodValue` directly to the
sleep-stage handler. Its newer feature-gated stateless bedtime detector instead skips
ring bedtime events and derives periods from feature-session, state-change, motion,
temperature, time-sync, and alert events at one-minute resolution. That detector's
dynamically delivered model is not embedded in the APK. The shared summary therefore
keeps the raw ring bounds alongside locally adjusted bounds, and only adjusts an end
when adjacent bedtime segments or sleep-only sensor evidence support it.

## Sleep coverage and refresh lifecycle

Unanalysed ring epochs are `0` (unknown), never wake. Both clients leave gaps and
withhold complete-night metrics/scores/debt for partial staging. The summary exports
`staging_source`, `staging_coverage_pct`, `staging_complete` and `captured_unix`.
iOS uses `stages_full` for calculations; `stages` remains the compact preview.
Apple Health skips unknown epochs. Web motion uses timestamped `series_t.motion` bars, with `series.motion_time` as a legacy fallback. iOS uses `series.motion_time` (normalized
positions), rendered as discrete measurements without interpolation.

SleepNet output timestamps are retained on both paths and mapped onto the bedtime
30-second grid. Input selection checks absolute time as well as relative counters;
Ring 5 quality flags gate beat validity. Batch windows carry capture time to select
the right boot. The latest iOS night rechecks its input fingerprint after store changes.

Automatic lifecycle sync requests are coalesced and concurrent summary reloads queue
one follow-up. iOS reports gate/clock/model stages and has a cooperative 180-second
analysis deadline; a native Torch forward cannot safely be forcibly interrupted, so
its watchdog reports the delay while retaining exclusive database ownership.
Desktop Python runners have a 180-second kill/reap timeout and drain stdout concurrently.

Validation uses synthetic cases; personal exports and model weights remain local.
A report JSON alone cannot replay Gen4 inference or prove the original bedtime.

GitHub iOS validation also compiles the TORCH Swift paths against a validation-only
C bridge and runs pure planning/alignment tests. This checks model plumbing, not
LibTorch inference; release projects never include the stub bridge.


### CLI configuration and community integration

`--db` and `--key-file` override `OURA_DB_FILE` and `OURA_KEY_FILE`. Ring operations
look for adjacent `oura.key`, then a single `oura-<serial>.key`; multiple serial keys
require an explicit selection. Pairing saves its default key beside the database.
Saved-data commands do not load auth keys.

CLI display commands default to the current local UTC offset on Unix (UTC on
other platforms). `--tz-offset` accepts fractional hours, e.g. `5.5`, `5.75`, or
`-3.5`. This remains a fixed offset across the requested history, not a named
zone with historical DST/travel rules; use an explicit offset when needed. The
existing integer-offset iOS FFI contract is retained.

Multiple `ring_start` markers between disagreeing anchors make the interval
between the first and last reboot undatable. Rust, Python, and Swift agree on
this rule; model caches are invalidated for the clock/bedtime changes.

The web BLE actions (sync, live HR, feature mode) share one operation gate. Live
HR drains stderr concurrently, retains only a bounded tail, and kills/reaps a
stalled or disconnected child before releasing the gate. Hardware/firmware live
HR support still depends on the pinned BLE implementation.
