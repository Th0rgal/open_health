# open_health — repo guide for agents

Local-first health apps (native iOS app + web dashboard) for the Oura ring, built on
[open_oura](https://github.com/Th0rgal/open_oura), which owns the BLE protocol, sync,
decoders and ported algorithms (pulled in as git dependencies). This repo holds the
shared summary brain, the two clients, blood/DNA analysis, and the model runners for the
networks that have no Rust port yet (activity / illness / CVA, as decrypted TorchScript). For reverse-engineering
details, see open_oura's `docs/`.

## ⚠️ Two clients render the same data — keep them in sync

There are **two user-facing apps** and a change usually belongs in **both**:

- **Web dashboard** — `dashboard/web/` (vanilla JS) served by `crates/oura-cli/src/dashboard.rs`.
- **Native iOS app** — `apps/ios/OuraApp/` (SwiftUI) on `crates/oura-core` (UniFFI).

Both render the JSON from the **single shared brain `crates/oura-summary` (`build_summary`)**.

Before you finish a feature, check it against **`docs/clients-web-and-ios.md`** (the
feature ↔ feature map) and apply it where it belongs:

- **New computed metric/field** → add once in `oura-summary`; render in **both** `app.js`
  **and** `OuraApp.swift`.
- **New visualization/UI** → do it in **both** `app.js` **and** `OuraApp.swift`.
- **New model** → wire **both** a `tools/run_*_model.py` (web `PythonRunner`) **and** the
  iOS on-device path (`apps/ios/OuraApp/TorchBridge.mm` + a `*Model.swift`).

If you intentionally do only one client, say so and note it in the "Known gaps" section of
`docs/clients-web-and-ios.md`.

## Storage rules

- `events` holds only what the ring sent. The phone's own clock points (phone anchors)
  go in `phone_anchors`; read the clock stream through `events_with_anchors` /
  `clock_events_relation`, never by selecting tag 66 from `events`. Details in
  `docs/clients-web-and-ios.md` (ring time section).
- `sync_time_app` must send exact unix seconds (`12 09 <u64 unix> <tz>`); a quantized or
  hashed clock dates the ring's whole boot epoch wrongly.

## Building / running

- Web dashboard: `oura dashboard` (see `dashboard/README.md`).
- iOS (simulator): `apps/ios/OuraApp/build_run.sh` (model-free) or `build_run_torch.sh`
  (on-device torch models). TestFlight: `apps/ios/TESTFLIGHT.md`.
- Models, `libtorch`, `oura.db`, and auth keys are gitignored — never commit them.
