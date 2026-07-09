# Web dashboard and iOS app

`open_health` currently has two product surfaces with different roles:

| | Web dashboard | Native iOS app |
| --- | --- | --- |
| Where | `dashboard/web/` served by `crates/oura-cli/src/dashboard.rs` | `apps/ios/OpenOura/` |
| Entry | `oura dashboard` -> `http://127.0.0.1:8090` | `./apps/ios/build-rust.sh`, then `cd apps/ios && xcodegen generate && open OpenOura.xcodeproj` |
| Rust surface | `crates/oura-summary` plus the Python model runners | `crates/oura-ffi` C ABI over `open_oura`'s protocol core |

The web dashboard is the local health dashboard: summary JSON, model runners, DNA,
and blood routes.

The iOS app is the native BLE client migrated from `open_oura`: pairing/importing
the ring key, direct CoreBluetooth sync, live HR/HRV/motion, and local history
rendering. It intentionally keeps the `OpenOura` product name and bundle id
`md.thomas.openoura` for TestFlight continuity.

Reusable protocol, BLE, storage, and portable analysis work belongs in
`open_oura`. Product surfaces, dashboard APIs, iOS app packaging, DNA, blood, and
model orchestration belong in `open_health`.
