# Open Health

Your health data, on your own devices.

A native iOS app and local web dashboard for Oura: sleep, activity, heart rate,
HRV and long-term trends. Built with SwiftUI and Rust, with direct Bluetooth sync
and on-device analysis.

<p align="center">
  <img src="docs/screenshots/overview.png" width="32%" alt="Daily overview with sleep, activity and vital trends" />
  <img src="docs/screenshots/sleep.png" width="32%" alt="Sleep report with sleep stages and overnight signals" />
  <img src="docs/screenshots/activity.png" width="32%" alt="Activity report with movement, steps and workouts" />
</p>

<p align="center"><sub>iOS · Overview, sleep and activity · Real data from a Ring 5, July 2026</sub></p>

The web dashboard also brings together local blood reports and DNA analysis.
Ring communication and portable algorithms are powered by
[open_oura](https://github.com/Th0rgal/open_oura).

## Get started

**iOS** — [Build with Xcode](apps/ios/TESTFLIGHT.md) or [Xcode Cloud](apps/ios/XCODE_CLOUD.md).

**Web** — Run locally, then open [localhost:8090](http://127.0.0.1:8090):

```sh
cargo run --release -p oura-cli -- dashboard
```

[Dashboard guide](dashboard/README.md) · [Algorithms](docs/algorithms/README.md) · [Architecture](docs/clients-web-and-ios.md) · [open_oura boundary](docs/open-oura-boundary.md)

## Models

The repository contains no third-party model files. The activity, illness, CVA and
Oura sleep-staging models (see [model runners](docs/model-runners.md)) are not
distributed. If a build lacks them, the matching widgets still appear and show a
notice naming what is missing. Sleep staging has a built-in option, a community-trained
tree ensemble that approximates the official staging and is always available. Settings lets you choose
between it and the Oura staging when those model files are present.

MIT licensed. See [LICENSE](LICENSE).
