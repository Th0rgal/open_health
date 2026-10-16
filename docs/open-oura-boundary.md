# open_health and open_oura: what lives where

open_health builds on [open_oura](https://github.com/Th0rgal/open_oura). open_oura owns the ring
protocol, sync, event decoding, storage, and the ported score algorithms. open_health owns what
chooses and shows data to a person.

## Division

| Piece | Location |
| --- | --- |
| Ring protocol, sync, event decoding, storage (including phone anchors) | open_oura: `oura-protocol`, `oura-link`, `oura-store` |
| Capture features and workout start and stop on the ring | open_oura: `OuraClient` |
| Score algorithms (sleep, readiness, activity, baselines, sleep regularity) | open_oura: `oura-analysis::ported` |
| Night summary, sleep staging, bedtime detection, activity days, window series | open_oura: `oura-analysis::ported` |
| Ring clock across boots, undated-event handling | open_health: `oura-summary::ring_time` |
| Summary JSON for both clients (`build_summary`) | open_health: `oura-summary` |
| Reading stored events into the open_oura inputs | open_health: `oura-summary` |
| Model runners, libtorch ops, UniFFI bindings | open_health: `oura-core`, `apps/ios` |
| iOS app and web dashboard | open_health |

A computation that exists in both repos is fixed in open_oura only. `oura-core` wraps open_oura
calls for Swift and keeps no ring logic. Activity tags and user-started exercises are stored in
`activities.json` beside the database and are not part of any open_oura format.

## Dependency pin

Cargo fetches the open_oura crates from
[manueldeprada/open_oura](https://github.com/manueldeprada/open_oura) at `rev`
`a0d3eada2fa8a48f16217e5ccfca6680eddf9c1e`, set in the manifests of `oura-cli`, `oura-core`,
`oura-summary`, and `oura-ffi` (all four use the same `rev`). That revision carries the changes in
[Th0rgal/open_oura#32](https://github.com/Th0rgal/open_oura/pull/32). When the pull request is
merged, point the four manifests at `https://github.com/Th0rgal/open_oura` with the merged commit
as `rev`, then run `cargo update` for the open_oura crates.

## Changing shared logic

1. Make the change in open_oura with a test vector, and update the page in its `docs/algorithms/`.
2. Use it here by pushing the open_oura commit and bumping the `rev` in the four manifests.
3. Rebuild and run `cargo test --workspace`.
