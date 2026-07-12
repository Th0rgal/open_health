# Running Oura's activity-detection model on our data

`tools/run_activity_model.py` feeds our stored ring events into Oura's decrypted
TorchScript `automatic_activity_detection_3_1_11.pt` and prints detected activity
segments — **no raw IMU / RData needed**, it runs on the windowed signals we
already sync.

**This is the engine behind `oura sessions`.** The Rust CLI no longer ships a
temperature/MET heuristic; `oura sessions` shells out to this script (it locates
the repo's `.venv/bin/python`, falling back to `python3`). Use the CLI for the
normal path and this script directly for `--json`, `--verbose`, or a custom
`--threshold`/`--min-duration`.

```
python tools/run_activity_model.py [DB] [--tz HOURS] [--threshold P] [--date YYYY-MM-DD] [--json]
oura sessions --tz-offset 1            # same thing, via the CLI
```
`DB` defaults to `./oura.db` then `captures/ring5.db`. Requires `torch` (CPU is
fine) in the venv. The model lives in `notes/models/`.

## In-process (Rust + LibTorch, no Python at runtime)

Built with `--features torch`, `oura sessions` can run the base model in-process via
the `tch` crate. That legacy path does not yet run `steps_motion_decoder`; use the
default Python-backed command (and the web dashboard, which uses it) for the
Android-parity labels documented here.

On Apple Silicon the only libtorch is the pip wheel, so the repo **venv is aligned
to torch 2.9.0** (Python 3.11) — the exact version `tch 0.22` targets — and we link
against it with **no version-check bypass**:

```
export PATH="$PWD/.venv/bin:$PATH"
export LIBTORCH_USE_PYTORCH=1
cargo build --features torch
oura sessions --tz-offset 1     # no DYLD_LIBRARY_PATH needed — build.rs bakes the rpath
```

`build.rs` embeds the venv torch `lib/` as an rpath, so the binary loads
`libtorch_*.dylib` without `DYLD_LIBRARY_PATH`. The default build (no feature)
needs no libtorch and keeps using the Python runner. Note LibTorch prints a
one-time `searchsorted` perf warning to stderr (harmless; stdout/JSON stay clean).

Version coupling: `tch X` pins one exact libtorch (0.20→2.7, 0.22→2.9, 0.24→2.11);
there is **no 2.8 release**. The venv torch must match the `tch` pin, and torch
≥2.9 needs Python ≥3.10. If you bump either, bump both together.

## Android parity

The decompiled Android app uses this same 3.1.11 model. Its important preprocessing
steps are now mirrored here and in iOS:

- one inference per local calendar day; model time is minutes since local midnight;
- a 10-minute minimum duration;
- all three gait sub-windows from `steps_motion_decoder_2_0_0`;
- the decoder's columns reordered through Android's `StepMotionFeature` schema.

The ring exposes the decoder input directly as paired `real_step` events (0x7e/0x7f),
so raw RData is not required. On a retained Ring 5 replay this changes a known hike
from `cycling` 0.45 to `hiking` 0.97, while a known bike remains `cycling` 0.92 and
an immersion interval is classified `swimming` 0.99.

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
| stepmotion | 12 cols — timestamp + 11 gait features | paired 0x7e/0x7f → `steps_motion_decoder` |

Output `workouts[n,9]` = `[start_min, end_min, is_workout_prob, id1,p1, id2,p2,
id3,p3]` (corrected from the spec, which called col 2 "duration"). `id`→name via
the behavior table in the script (swimming=13, walking=14, cycling=5, …).

## Gotchas learned the hard way

- **Run each day independently.** This is both the Android contract and keeps the
  minute axis exactly representable in float32.
- **Decoder order is not AAD order.** `steps_motion_decoder` emits
  `sum,y,z,total,strideFreq,…`; Android's `px.b` maps that to
  `firstFreq,firstAmp,high,mid,gait,…,sum,total,y,z` before AAD.
- **stepmotion boundary rows must span the day's MET range.** The model derives
  `last_valid_time` from every series; missing boundaries can truncate a day.
- **Ring `ring_timestamp` is device-relative deciseconds**, not unix — anchor to
  the latest event's `captured_unix` (as `oura sessions` does).
- Open calibration unknowns: ACM `avg_*` scaling (env `ACM_SCALE`, default 1) and
  temperature-probe choice (using index 0).

GPS and past-activity inputs are still absent, so sports without gait can remain
ambiguous. `--no-stepmotion` exists only to compare against the old partial pipeline.
