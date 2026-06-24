# Running Oura's activity-detection model on our data

`tools/run_activity_model.py` feeds our stored ring events into Oura's decrypted
TorchScript `automatic_activity_detection_3_1_11.pt` and prints detected activity
segments — **no raw IMU / RData needed**, it runs on the windowed signals we
already sync.

```
python tools/run_activity_model.py [DB=captures/ring5.db] [TZ_OFFSET_HOURS=1]
```
Requires `torch` (CPU is fine) in the venv. The model lives in `notes/models/`.

## What works / what doesn't

- ✅ **Activity/workout *detection*** works from our data. On `ring5.db` it finds
  4 segments incl. the real swim (10:58–11:21, 23 min) with the highest
  `is_workout` confidence (0.91).
- ⚠️ **Activity *type* classification is unreliable.** The swim is typed
  walking/yardwork/basketball ~0.42 (low, tied), not `swimming`. The model's main
  type discriminator is the **`stepmotion`** (stride/gait) channel, which we
  **stub with NaN** — we have no source for it (it comes from
  `steps_motion_decoder` fed raw ACM, i.e. the capability-locked RData path; see
  `docs/rdata-capacity-probe.md`). HR is also unreliable underwater.

So: auto-detecting *when* activities happen is reachable today; reliably typing
them (esp. swimming) is gated on the same raw-data wall as everything else.

## I/O contract (as implemented)

forward args (TorchScript order): `context, user, met, stepmotion, motion,
temperature, heartrate, location=None, past_activities=None, probability_threshold,
minimum_duration_minutes, allow_non_wear`.

All series are float32 2-D, **column 0 = time in minutes** on one shared axis.

| input | cols | source (decoded events) |
| --- | --- | --- |
| met | `[t, met]` | 0x50 `met[]` (1 value/min, expanded) |
| motion | `[t, orient, motion_s, ax, ay, az, NaN(regular_motion), low_int, high_int]` | 0x47 |
| temperature | `[t, temps_c[0]]` | 0x46 |
| heartrate | `[t, mean(hr_bpm)]` | 0x80 |
| stepmotion | 12 cols — **NaN stub spanning [first,last] t** | none |

Output `workouts[n,9]` = `[start_min, end_min, is_workout_prob, id1,p1, id2,p2,
id3,p3]` (corrected from the spec, which called col 2 "duration"). `id`→name via
the behavior table in the script (swimming=13, walking=14, cycling=5, …).

## Gotchas learned the hard way

- **Time axis must be float32-exact.** Unix-minutes (~29.7 M) exceed float32's
  2²⁴ integer precision and silently break the model's exact-equality time
  alignment → rebase by whole days (preserves time-of-day, which the model uses
  mod-1440).
- **stepmotion stub must span the full time range.** The model derives
  `last_valid_time` from the last timestamp of *every* series; a single-row stub
  at the first minute truncates everything to one minute and crashes HR alignment.
- **Ring `ring_timestamp` is device-relative deciseconds**, not unix — anchor to
  the latest event's `captured_unix` (as `oura sessions` does).
- Open calibration unknowns: ACM `avg_*` scaling (env `ACM_SCALE`, default 1) and
  temperature-probe choice (using index 0).

## To improve type accuracy

Wire up `steps_motion_decoder_2_0_0.pt` to produce real `stepmotion` — but it
needs raw ACM, which is the RData capability we can't enable on a consumer ring.
Without it, type classification stays weak; detection is the usable capability.
</content>
