# open_health

Local-first health applications built on top of
[`open_oura`](https://github.com/Th0rgal/open_oura).

This repository owns the product surfaces: the web dashboard, the iOS app, the
shared summary layer they render, and the non-ring health integrations such as
DNA VCF scoring and local blood report PDF import. The low-level Oura protocol,
BLE client, storage, and portable metric algorithms live in `open_oura` and are
consumed here as Git dependencies.

## What lives here

- **`dashboard/web/`**: vanilla HTML/CSS/JS health dashboard served locally.
- **`apps/ios/`**: SwiftUI iOS client and generated Rust FFI bindings.
- **`crates/oura-cli`**: app-oriented CLI entrypoint, including `oura dashboard`,
  DNA explorer routes, blood PDF import, model runners, and local dashboard APIs.
- **`crates/oura-summary`**: shared dashboard summary JSON consumed by web and iOS.
- **`crates/oura-core` / `crates/oura-ffi`**: native/iOS FFI surfaces.
- **`crates/oura-dna` + `dna/`**: local VCF trait/PGS scoring catalog and helpers.
- **`tools/`**: model runners and app-oriented analysis utilities.

## Boundary with open_oura

`open_health` depends on `open_oura` for:

- `oura-protocol`: packet framing, request builders, auth crypto, event decoders.
- `oura-link`: BLE transport/client and sync/live stream orchestration.
- `oura-store`: SQLite event/readings store.
- `oura-analysis`: portable metric algorithms.

Keep reusable protocol/library work in `open_oura`. Keep app UX, dashboard APIs,
iOS presentation, DNA, blood, and model orchestration here.

## Quick start

```bash
cargo build --release
cargo run -p oura-cli -- dashboard \
  --tz-offset 1 \
  --dna-files ~/Documents/official/health/dna/files \
  --blood-files ~/Documents/official/health
```

Open `http://127.0.0.1:8090`.

The dashboard reads local files only. Genome files, blood PDFs, generated
`blood.db`, Oura auth keys, and raw captures should stay outside Git.

## Validation

```bash
cargo test --workspace
```

For the iOS app, use the scripts under `apps/ios/` after rebuilding the Rust FFI
artifacts.
