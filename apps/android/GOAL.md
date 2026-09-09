# open_oura — Android app · Goal

A native Android client to the same local Rust core as the web dashboard and the iOS
app. Same data, same numbers — a **calm, instrument-grade** reading of your ring, with
a quiet data-science aesthetic. Everything on-device; nothing leaves the phone.

This is the third client. The contract it must honour is
[`docs/clients.md`](../../docs/clients.md): all three render the **same
`build_summary()` JSON**, and a new computed field belongs in `crates/oura-summary`
once, not three times.

## Design language — thomas.md Quiet Ink

Identical palette to iOS (`Theme.swift` ↔ `ui/Theme.kt`; the hex values are shared
verbatim, so a palette change belongs in both).

- **Paper** `#fbfaf6` light · `#131110` dark. Hierarchy from hairlines and weight.
- **Ink** headings `#26231e` / `#efebe2` · body `#57534b` / `#cfc9bf` · muted
  `#6e695f` / `#a8a195` · rules `#e7e3da` / `#2c2925`.
- **Color is semantic.** Charts and numbers sit in warm ink/gray. Green only when
  something is genuinely good, orange/red only when there is a problem. Sleep stages
  are the exception: deep / light / REM / wake keep distinct hues.
- **Type** — iOS uses New York (system serif) and SF Mono. Android has neither, so we
  take the platform's closest equivalents (`FontFamily.Serif` / `FontFamily.Monospace`)
  rather than shipping lookalike webfonts. This is a deliberate, documented divergence.
- **Surfaces** paper + 1px rules, 10dp radius. Auto light/dark from the system.

## Architecture

- **Jetpack Compose**, `minSdk 28`, `targetSdk 36`, ABIs `arm64-v8a` + `x86_64`.
  Every chart is hand-drawn in Compose `Canvas` — no third-party UI dependencies, the
  same constraint the iOS app works under.
- **Shared Rust core** via `crates/oura-core` (UniFFI) built as `liboura_core.so` and
  bound with UniFFI's Kotlin backend. The *same* `#[uniffi::export]` surface the Swift
  client uses — `summary_json`, `quick_summary_json`, `rmssd`, and
  `RingSession`/`BleWriter`/`SyncProgressListener` — regenerated with
  `--language kotlin`. **No Rust code is Android-specific.**
- **BLE**: `BluetoothGatt` implements the `oura-link::Transport` shape; auth, the
  protocol and the drain stay in Rust, exactly as CoreBluetooth does on iOS.
- **ML models**: the same TorchScript `.ptl` lite-interpreter modules as iOS
  (`tools/export_mobile.py`), run through a JNI bridge that ports `TorchBridge.mm`.

### Where Android does better than iOS

iOS has no unrestricted background CPU and no scheduled sync — it only syncs while the
app is in front. Android runs a true **autonomous background sync**: a WorkManager
`PeriodicWorkRequest` fires `RingSyncWorker` every 6 hours (`ble/SyncScheduler.kt`),
on a `connectedDevice` foreground service with an ongoing notification, holding the
real reference-counted `PARTIAL_WAKE_LOCK` the official Android client uses. The
scheduled run retries an unreachable ring with exponential backoff (5 s → 40 s, capped
at 1 min, 5 attempts). App start and the manual Sync button enqueue the same worker
over the shared headless `ble/SyncEngine.kt`, so a long history drain survives the app
going to the background and there is exactly one sync path.

## Building

The toolchain deliberately does **not** invoke the NDK's own `clang`: Google ships it
as `linux-x86_64` only, which on an arm64 host runs under qemu emulation. The NDK
*sysroot* is host-agnostic, so `android-env.sh` points the host's clang at it instead.

```bash
./build-jni-libs.sh                  # Rust core -> jniLibs/ + Kotlin bindings
JAVA_HOME=/path/to/jdk21 ./gradlew :app:assembleLiteDebug
```

`lite` is the model-free flavor (the counterpart of `apps/ios/OuraApp/build_run.sh`) and
needs nothing but the Rust core. `full` additionally needs LibTorch for Android
(`spike/build_libtorch_android.sh`) and the decrypted `.ptl` models — both gitignored
and absent from CI, exactly as on iOS.

AGP does not run on JDK 25; use a JDK 21.

## Feature parity

Everything in the iOS app: Today/digest, the unified day card, vitals with trend
sheets, the full-page sleep report (polysomnograph, clinical metrics, autonomic grid),
sleep debt, Symptom Radar, cardiovascular age + VO₂max, the full-page activity report
(MET profile, sessions), the previous-days browser, device & data health, BLE sync with
ring-key entry, the profile editor, and health export (Health Connect in place of
HealthKit). See the feature↔feature table in `docs/clients.md`.

## Non-goals (v1)

Cloud sync · accounts · live realtime · the DNA explorer and blood panel (deliberately
web-only, as on iOS).
