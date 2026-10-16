# iOS stability pass (build 26)

The diagnostics from build 25 establish repeated storage failures and interrupted
sessions, not fourteen confirmed crashes. The app now labels the evidence rather
than inferring a cause from a missing termination callback.

## Changes

- Diagnostic summaries, original detailed exports, lifecycle records, operation
  IDs, stage timings, process footprint, disk availability and MetricKit reports.
  Local retention reserves room for a 2 MiB live segment within a 32 MiB budget;
  the pending write queue holds at most 256 records. Authentication traffic and
  nearby-device identities are excluded from routine logging.
- System SQLite throughout the iOS process. Read-only summary opens do not mutate
  bundled data. Each received batch and its cursor commit together with FULL
  durability; failures retain operation names and primary/extended SQLite codes.
  The app preserves data after errors and exposes an explicit integrity check.
- One database work owner, cancellable model generations, safe reset, background
  pause, foreground resume, and explicit Rust interruption on transport closure.
  GATT writes have a ten-second deadline; all BLE mutable state is confined to
  the delegate queue. The sync sheet can be dismissed or the sync paused.
- Re-iterable SQLite event streams replace the all-history dictionary array.
  Sleep and activity dirty inputs are released per unit. Illness IBI inputs are
  parsed once into a disposable indexed SQLite workspace, then read one night
  at a time. The workspace is removed after completion/cancellation or replaced
  on the next run after a kill. CVA selection keeps the existing last 4,000
  segments while bounding construction memory. Illness and CVA inference results
  are cached; old generations cannot publish UI or enqueue HealthKit exports.
- Successful summary caches now also preserve workouts and illness results.

The changed upstream storage crate is vendored for a reproducible review build.
The store changes it describes are in open_oura (`crates/oura-store`).
No health-data schema columns or medical model definitions were changed. Two
indexes are built on the first writable open after upgrading; a large existing
history can make that first initialization slower.

## Automated validation

Run Rust tests:

```sh
cargo test -p oura-core -p oura-store -p oura-summary --lib
```

Rebuild the matching FFI library, Swift and headers:

```sh
bash apps/ios/build-xcframework.sh
```

Generate with `project.yml` for models or `project-ci.yml` for model-free builds,
then run the OuraApp scheme's tests on an arm64 iPhone simulator. Both specs
include OuraAppTests. The model-enabled build requires the existing local Torch
frameworks and model resources documented in the iOS build instructions.

Tests cover transaction rollback on failed insert or checkpoint, idempotent
replay, read-only opening, Rust cancellation during authentication, SQLite error
classification, exclusive work ownership, cancelled generations, session
classification, bounded log rotation, re-iterable event streams, reboot mapping,
and preservation of the last 4,000 CVA segments.

## Synthetic memory benchmark

`apps/ios/benchmarks/make-history.py` creates 1,735,704 synthetic events. Compile
`streaming-events.swift` with the production EventStore.swift using `swiftc -O
-D TORCH`, an SQLite bridging header, and `-lsqlite3`. For the baseline, use the
pre-change EventStore.swift from git. Run each executable separately under
`/usr/bin/time -l` against the same fixture.

Measured on this Mac with the final streamed reader:

| Reader + clock mapping | Peak footprint | Elapsed |
| --- | ---: | ---: |
| Previous all-history array | 1,404,765,624 bytes | 6.15 s |
| Streamed reader | 11,370,952 bytes | 5.46 s |

Both produced 1,735,704 rows, checksum 50,348,851,995,600 and latest clock anchor
1,712,000,000. This is a 99.2% reduction for event reading/clock mapping. It is
**not** an end-to-end device memory measurement or a claim of model-output parity
for every real-world history. The fixture result does not predict every workload: re-reading streams trades
CPU/I/O for bounded RAM. Model queries restrict tags and sleep ranges where
semantics allow it. Illness uses a disposable indexed workspace to preserve capture order and
clock recovery while avoiding repeated JSON decoding. Its cold preparation
requires temporary disk space proportional to the normalized IBI history.

## Physical-device acceptance still required

On an iPhone with a real ring, validate pause/resume during scan, transfer,
transaction commit, and each inference stage; repeated foreground transitions;
Bluetooth-off/disconnect; protected-data transitions; unavailable storage;
and recovery after a process kill. Verify last committed cursors and event counts
across interruptions, that ordinary background sessions are not called crashes,
and that warm unchanged runs show cache hits without inference.

Measure whole-app peak footprint and UI responsiveness on the actual 1.7M-event
history. The overall 50% memory-reduction target and long-history numerical parity
remain device/data acceptance criteria, distinct from the synthetic reader result.
Keep matching Release dSYMs with any distributed build. No release was published.

## Results for this checkout

- 29 Rust tests passed (5 FFI/core, 8 storage, 16 summary).
- 8 model-enabled simulator tests passed on iPhone 17 Pro / iOS 26.5.
- Model-free simulator build and model-enabled Release device build succeeded.
- Device app and dSYM UUIDs match: `64C44406-A317-3D7C-8969-8516DF3822A8`.
- Device executable links `/usr/lib/libsqlite3.dylib`; the rebuilt Rust iOS
  archive does not define another SQLite implementation.
- `git diff --check` passes in both repositories.

The unsigned app, matching dSYM, test summary and build/benchmark logs are in
`local/validation/build26/` (gitignored). The paired iPhone was unavailable, so
physical ring tests and whole-app memory acceptance have not been performed.
