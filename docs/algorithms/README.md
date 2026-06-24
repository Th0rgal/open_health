# Algorithms (ecore port)

Oura computes its daily metrics **on the phone**, in the native `ecore` engine
(`libappecore.so`) — not in the cloud (the cloud is storage/sync). The one
exception is the **sleep hypnogram**: ecore *consumes* a pre-computed 30-second
stage array and only produces the staging *features*; the stager itself is the
on-device **SleepNet** PyTorch model (encrypted `*.pt.enc` in `oura_models.apk`)
and/or the ring firmware. Everything *downstream of staging* is deterministic and
portable.

This directory documents each metric we port into `oura-analysis`. Source
addresses refer to functions in the decompiled `libappecore.so` (see
`native-decoder.md` for the Ghidra method). Per-metric detail files are added as
each is ported; this index is the status table.

## Status

| Metric | ecore source | Rust impl | Status |
| --- | --- | --- | --- |
| HRV (RMSSD) | `hrv @ 0x1e7984` (`sqrt(mean(diff(ibi)^2))`) | `oura-analysis::hrv` | ✅ ported + tested; validated on overnight IBI (RMSSD ~101 ms) |
| SpO2 (simple) | `spo2_simple_calculate @ 0x22ad50` (`a+b·R+c·R²`, clamp 0–120) | `oura-analysis::spo2` | ✅ ported + tested; needs per-device {a,b,c} |
| Personal baseline | `baseline_update_lt_mean_and_dev @ 0x1dad04` (asymmetric EMA, anneals by age; int16 ×8) | `oura-analysis::baseline` | ✅ ported + tested (EMA; per-metric clamp tables unresolved) |
| Nightly temperature + baseline | `nightly_temperature_calculate @ 0x203520`, `baseline_calculate_temperature_baseline @ 0x1db4d0` (7-sample median → 30-min window) | `oura-analysis::temperature` | ✅ ported + tested |
| Breathing rate | `breathing_rate_calculate_averages @ 0x27342c` (IBI→RR @4 Hz→IIR→band variability) | — | ⏳ to port |
| Sleep durations / efficiency / latency | `calculate_sleep_score_numerical @ 0x1f4444` (decodes 30 s nibble stages) | `oura-analysis::sleep` | ✅ decode+summary ported (aggregation reconstructed) |
| Sleep score + contributors | `ecore_sleep_score_calculate @ 0x1f5c20`, limits `…_init_limits(_v2) @ 0x1f5a3c` (piecewise from age byte) | — | ⏳ to port |
| Sleep debt | `sleep_debt_calculate @ 0x215658` | `oura-analysis::sleep_debt` | ✅ ported + tested |
| Readiness score + contributors | `readiness_calculate @ 0x20897c`, `recovery_run @ 0x20915c` (2 versions; baseline-deviation contributors) | — | ⏳ to port (weights partly obfuscated) |
| Rest/recovery mode | `rest_recovery_* @ 0x20bf38…` | — | ⏳ to port |
| Activity score + contributors | `get_activity_score_from_raw_100 @ 0x1d781c` (nested weighted sum, weights 15/10) | — | ⏳ to port (formula recovered) |
| Activity targets / cals / MET | `actinfo_target_to_cal @ 0x1cd2c8`, `actinfo_update_5_min_classification @ 0x1cd640` | — | ⏳ to port |
| Cycle prediction / tracking | `cycle_prediction_calculate @ 0x1e2864`, `cycle_tracking_calculate @ 0x1e4244` | — | ⏳ to port |
| **Sleep hypnogram (staging)** | **not in ecore** — SleepNet model (`sleepstaging_2_6_0.pt.enc`) / ring firmware | `oura-analysis::sleepnet` | ⏳ model is encrypted; decrypt + run (Python first) |

## Device vs cloud (corrected)

Earlier we read the `score` + `*_algorithm_version` JSON fields as cloud-computed.
They are actually computed **on-device** by ecore (versions `v1/v2/nssa/sleepnet`
identify *local* algorithms), written to the local Realm `DbSleep`/`DbDaily*`, then
**uploaded**; the cloud serves the same locally-produced doc back on sync. There is
**no network code in ecore** — all tuning is embedded `get_default_*` tables or
host-supplied via `set_*` setters.

**Reproducible offline by porting ecore:** sleep/readiness/activity scores, sleep
debt, durations/efficiency, nightly temperature + baseline, HRV/RMSSD, resting-HR
percentiles, breathing rate, simple SpO2, activity targets/calories/MET, cycle.

**Not from ecore alone:** the **hypnogram** (needs the SleepNet model or the ring's
staging), **SpO2 OVI** (NaN stub) and **BDI/apnea** scoring (delegated), and the
exact **algorithm-version + baseline-state history** required to match Oura
bit-for-bit.

## Persisted state an independent client must carry across days

ecore is stateless-per-call; the host re-injects state each night via typed
objects: recovery state (+prev), temperature baseline, previous sleep periods,
cycle-tracking state, and the SpO2 main storage (the only native binary serializer,
versioned TLV). Mirror these in `oura-store` so baselines accumulate.
