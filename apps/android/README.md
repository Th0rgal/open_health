# open_oura — Android client

The third client on the shared Rust core. See [`GOAL.md`](GOAL.md) for the product goal
and [`../../docs/clients.md`](../../docs/clients.md) for the feature ↔ feature map that
keeps web, iOS and Android in sync.

## Prerequisites

| | |
| --- | --- |
| Android SDK | platform 36, build-tools 36, and an NDK (28.x tested) |
| JDK | **21** — AGP does not run on 25 |
| Rust | `rustup target add aarch64-linux-android x86_64-linux-android` |
| Clang | `lld` for the Rust build; for the `full` flavor also `clang-19`, matching the NDK's clang major version (see the toolchain note below) |

Point `local.properties` at your SDK (`sdk.dir=/path/to/android-sdk`), or set
`ANDROID_SDK_ROOT`.

## Build

```bash
./build-jni-libs.sh
JAVA_HOME=/path/to/jdk21 ./gradlew :app:assembleLiteDebug
```

`build-jni-libs.sh` cross-compiles `crates/oura-core` into
`app/src/main/jniLibs/<abi>/liboura_core.so` and regenerates the UniFFI Kotlin bindings in
`generated/`. Both are gitignored except the bindings, which are checked in exactly as
`apps/ios/generated/oura_core.swift` is.

### Flavors

- **`lite`** — model-free. Needs nothing but the Rust core. This is the counterpart of
  `apps/ios/OuraApp/build_run.sh` and the one CI can build.
- **`full`** — adds the on-device TorchScript models. Needs LibTorch for Android
  (`spike/build_libtorch_android.sh`) and the decrypted `.ptl` files in
  `app/src/main/assets/`. Both are gitignored, as on iOS.

```bash
# apt install clang-19 lld-19   # must match the NDK's clang major version
#
# PyTorch's build generates C++ from Python during configure. Modern distros refuse
# `pip install --user`, so the script looks for the repo venv:
python3 -m venv ../../.venv && ../../.venv/bin/pip install pyyaml typing_extensions setuptools

./spike/build_libtorch_android.sh arm64-v8a     # long — hours on a small machine
python ../../tools/export_mobile.py             # produces the .ptl files
cp ../../notes/models/mobile/*.ptl app/src/main/assets/
JAVA_HOME=/path/to/jdk21 ./gradlew :app:assembleFullDebug
```

A `full` build without LibTorch still compiles and runs; `TorchBridge` reports the missing
library as a model error instead of crashing, and the model-free panels keep working.

## Tests

```bash
JAVA_HOME=/path/to/jdk21 ./gradlew :app:testLiteDebugUnitTest
```

These are plain JVM tests over the logic that is duplicated across clients — day pairing by
wake date, clinical sleep metrics, sleep debt and the personalised sleep need. `docs/clients.md`
requires those to stay identical in Rust, Swift and Kotlin, and these run headlessly, so they
are the cheapest place to pin a definition before changing it anywhere else.

## Running it

Ring sync needs real Bluetooth hardware, so the emulator can only exercise the UI against a
seeded database. On a device:

```bash
adb install -r app/build/outputs/apk/lite/debug/app-lite-debug.apk
```

Then open Sync, paste the ring's 32-hex auth key (exported from the phone that onboarded the
ring), and put the ring **on its charger** — a worn ring advertises only intermittently, and
it holds a single BLE link, so the official app being connected elsewhere will keep this one
from finding it.

## A note on the toolchain

Google ships the NDK toolchain as `linux-x86_64` only. On an aarch64 build host those
binaries run under qemu emulation — correct, but far too slow to build LibTorch. Everything
in `android-env.sh` exists to run the **host's own clang** against the NDK instead. On an
x86_64 host it is all still valid and costs nothing.

For Rust that is easy: per-target `CARGO_TARGET_*`/`CC_*` variables point cargo and the `cc`
crate at the host clang with `--target` and `--sysroot`. Two details bite anyway:

- `libunwind.a` lives in the NDK's clang **resource** directory, not the sysroot, so the
  per-arch path has to be passed as an explicit `-L`.
- `ld.lld` must be installed; a distro clang will not link Android targets without it.

For CMake — which is how PyTorch and AGP build native code — it is harder, because CMake's
Android support **ignores `-DCMAKE_C_COMPILER`** and derives the toolchain itself. Two
things then go wrong, and `android_cmake_ndk` exists to fix both by materialising a *shim
NDK*: everything symlinked to the real one, except the toolchain `bin/`, where
`clang`/`clang++` become wrapper scripts around the host compiler and the LLVM binutils
become the host's.

1. `Android-Determine.cmake` maps any non-`x86_64` Linux host to the tag `linux-x86`, finds
   no `toolchains/llvm/prebuilt/linux-x86/sysroot`, concludes the NDK predates the unified
   sysroot, and fails looking for the long-removed `platforms/android-NN/arch-ARCH` layout.
   The shim provides that tag name.
2. CMake passes `--target` but not `--sysroot`, because the NDK's clang infers both from
   where its binary sits. The wrapper supplies them.

The wrapper also restores two NDK driver defaults (`-rtlib=compiler-rt`,
`--unwindlib=libunwind`): a distro clang targeting Android still reaches for `libgcc`, which
no NDK has shipped in years.

**The resource directory is a merge, and it has to be.** The host clang's own headers must
match the host compiler — Google's clang is a fork whose `arm_neon.h` calls builtins such as
`__builtin_neon_vext_f16` that upstream clang of the same major version does not have, and
XNNPACK's fp16 microkernels will not compile against it. But a distro clang ships no
compiler-rt builtins or libunwind for Android targets, so linking needs the NDK's libraries.
`android_merged_resource_dir` therefore symlinks the host's `include` alongside the NDK's
`lib/linux`. For the same reason `HOST_CC` prefers a `clang-<N>` matching the NDK's clang
major version (19 for NDK 28); install it with `apt install clang-19 lld-19`.

One unrelated trap, in case it bites again: the workspace's `[profile.release] strip = true`
erases the `UNIFFI_META_*` symbols the bindings generator reads, and it then writes **no
files and still exits 0**. `build-jni-libs.sh` builds the host library with
`CARGO_PROFILE_RELEASE_STRIP=none` for that reason. The shipped `.so` keeps every runtime
symbol when stripped, so the packaged libraries stay small.
