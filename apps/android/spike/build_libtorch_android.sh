#!/bin/bash
# Build LibTorch + lite interpreter for Android from torch 2.9.0 source — the runtime
# that runs our bytecode-v10 .ptl models on-device. The Android counterpart to
# apps/ios/spike/build_libtorch_ios.sh.
#
#   ./build_libtorch_android.sh                 # arm64-v8a  → build_android_arm64/install
#   ./build_libtorch_android.sh x86_64          # emulator   → build_android_x86_64/install
#
# WHY FROM SOURCE, and not `org.pytorch:pytorch_android_lite`:
# the last published Maven artifact is 1.13.1 (2022). Our .ptl files are exported by
# tools/export_mobile.py against torch 2.9, and the models are full TorchScript pipelines
# with preprocessing and data-dependent control flow baked into the graph — exactly the
# things whose operator versions move. Building the same 2.9 runtime iOS uses is what
# makes the two clients bit-exact rather than approximately equal.
#
# HOST TOOLCHAIN: this does NOT use the NDK's own clang. Google ships the NDK toolchain
# as linux-x86_64 only, so on an aarch64 build host those binaries run under qemu
# emulation — correct but far too slow for a PyTorch build. The NDK *sysroot* is
# host-agnostic, so android-env.sh points the host's clang at it instead. On an x86_64
# host this is equally valid and costs nothing.
#
# The compile is the long part (tens of minutes to a few hours).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
# shellcheck source=../android-env.sh
. "$HERE/../android-env.sh"

ROOT="$REPO/local/libtorch-android"
SRC="$ROOT/pytorch"

ABI="${1:-arm64-v8a}"
case "$ABI" in
    arm64-v8a) TRIPLE=aarch64-linux-android; BUILDDIR=build_android_arm64 ;;
    x86_64)    TRIPLE=x86_64-linux-android;  BUILDDIR=build_android_x86_64 ;;
    *) echo "unsupported ABI '$ABI' (use arm64-v8a or x86_64)" >&2; exit 1 ;;
esac
CLANG_TARGET="$(android_clang_target "$TRIPLE")"
RUNTIME_ARCH="$(android_runtime_arch "$TRIPLE")"
echo "==> target: $ABI ($CLANG_TARGET) → $BUILDDIR"

echo "==> clone pytorch v2.9.0 (shallow; flash-attention/GPU submodules skipped)"
mkdir -p "$ROOT"
if [ ! -d "$SRC/.git" ]; then
    git clone --depth 1 --branch v2.9.0 https://github.com/pytorch/pytorch.git "$SRC"
fi
cd "$SRC"
git submodule deinit -f third_party/flash-attention 2>/dev/null || true
git submodule update --init --recursive 2>&1 | tail -3

# PyTorch's build generates C++ from Python during configure; it needs a host interpreter
# with pyyaml + typing_extensions, independent of the Android target. Prefer the repo venv
# (the iOS script does the same) because modern distros refuse `pip install --user`.
if [ -z "${PYTHON:-}" ] && [ -x "$REPO/.venv/bin/python" ]; then
    PYTHON="$REPO/.venv/bin/python"
fi
PY="${PYTHON:-$(command -v python3)}"
"$PY" -c "import yaml, typing_extensions" 2>/dev/null || {
    echo "the build's codegen needs pyyaml + typing_extensions on $PY" >&2
    echo "  python3 -m venv $REPO/.venv && $REPO/.venv/bin/pip install pyyaml typing_extensions" >&2
    exit 1
}
NINJA="$(command -v ninja)"
export CMAKE_POLICY_VERSION_MINIMUM=3.5   # cmake 4.x compat for old submodules

# CMake's Android support will not honour a -DCMAKE_C_COMPILER override, and on a
# non-x86_64 Linux host it cannot even find the NDK's unified sysroot. The shim NDK
# solves both: CMake picks "the NDK's" compiler by its own rules, and that compiler is a
# wrapper around the host's native clang. See android_cmake_ndk in android-env.sh.
SHIM_NDK="$(ANDROID_NDK_SHIM="$ROOT/ndk-shim" android_cmake_ndk)"
echo "==> shim NDK: $SHIM_NDK (host compiler: $HOST_CC)"

echo "==> cmake configure (Android $ABI / lite interpreter / CPU)"
cmake -GNinja -S . -B "$BUILDDIR" \
  -DCMAKE_MAKE_PROGRAM="$NINJA" -DPython_EXECUTABLE="$PY" -DPYTHON_EXECUTABLE="$PY" \
  -DCMAKE_SYSTEM_NAME=Android \
  -DCMAKE_SYSTEM_VERSION="$ANDROID_API" \
  -DCMAKE_ANDROID_ARCH_ABI="$ABI" \
  -DCMAKE_ANDROID_NDK="$SHIM_NDK" \
  -DCMAKE_ANDROID_STL_TYPE=c++_static \
  -DCMAKE_BUILD_TYPE=Release \
  -DANDROID_ABI="$ABI" -DANDROID_PLATFORM="android-$ANDROID_API" \
  -DINTERN_BUILD_MOBILE=ON -DBUILD_LITE_INTERPRETER=ON \
  -DBUILD_PYTHON=OFF -DBUILD_TEST=OFF -DBUILD_BINARY=OFF \
  -DBUILD_SHARED_LIBS=OFF \
  -DUSE_DISTRIBUTED=OFF -DUSE_MKLDNN=OFF -DUSE_NNPACK=OFF \
  -DUSE_PYTORCH_QNNPACK=OFF -DUSE_XNNPACK=ON \
  -DUSE_CUDA=OFF -DUSE_VULKAN=OFF -DUSE_NUMPY=OFF -DUSE_OPENMP=OFF \
  -DUSE_BLAS=OFF -DUSE_LAPACK=OFF \
  -DCMAKE_INSTALL_PREFIX="$PWD/$BUILDDIR/install"

echo "==> compile + install (long)"
cmake --build "$BUILDDIR" --target install -- -j"$(nproc)"

# Static libs, unlike iOS's dylibs: an APK has no dylib-embedding problem to solve, and
# linking them into our single JNI .so keeps one artifact per ABI.
DEST="$HERE/../libtorch-android/$ABI"
mkdir -p "$DEST"
cp -r "$SRC/$BUILDDIR/install/lib" "$SRC/$BUILDDIR/install/include" "$DEST/"
echo "==> done ($ABI) → $DEST"
ls "$DEST/lib/"*.a 2>/dev/null | head
