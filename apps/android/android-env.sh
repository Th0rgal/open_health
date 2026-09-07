# Sourced by the Android build scripts. Sets up a cross-compile toolchain for the
# Android NDK targets WITHOUT invoking the NDK's own clang binaries.
#
# Why: Google ships the NDK toolchain as linux-x86_64 only. On an aarch64 Linux
# host those binaries run under qemu binfmt emulation — correct, but far too slow
# to build anything large (LibTorch especially). The NDK *sysroot* (headers + libs)
# is host-agnostic, so we point the host's own clang at it instead and never touch
# the emulated binaries. On an x86_64 host this is equally valid.
#
# Override ANDROID_NDK_HOME / ANDROID_API to taste.

: "${ANDROID_SDK_ROOT:=$HOME/android-sdk}"
if [ -z "${ANDROID_NDK_HOME:-}" ]; then
    # newest installed NDK
    ANDROID_NDK_HOME="$ANDROID_SDK_ROOT/ndk/$(ls "$ANDROID_SDK_ROOT/ndk" | sort -V | tail -1)"
fi
: "${ANDROID_API:=24}"

# The prebuilt dir is named for the host Google built it on, not ours.
NDK_PREBUILT="$(ls -d "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/* | head -1)"
ANDROID_SYSROOT="$NDK_PREBUILT/sysroot"
[ -d "$ANDROID_SYSROOT" ] || { echo "no NDK sysroot under $ANDROID_NDK_HOME" >&2; exit 1; }

# The NDK keeps libunwind.a (and compiler-rt) in its clang RESOURCE dir, not the
# sysroot. The NDK's own clang finds it implicitly; our host clang has a different
# resource dir, so the per-arch path has to be passed as an explicit -L.
NDK_RUNTIME_DIR="$(ls -d "$NDK_PREBUILT"/lib/clang/*/lib/linux 2>/dev/null | sort -V | tail -1)"

# The NDK's own clang major version. The host compiler should match it, because the
# wrapper below hands the host compiler the NDK's clang RESOURCE directory — that is
# where compiler-rt's builtins, libunwind and the intrinsic headers live, and mixing
# major versions across that boundary is asking for trouble.
NDK_CLANG_MAJOR="$(basename "$(ls -d "$NDK_PREBUILT"/lib/clang/* 2>/dev/null | sort -V | tail -1)")"
NDK_RESOURCE_DIR="$NDK_PREBUILT/lib/clang/$NDK_CLANG_MAJOR"

if [ -z "${HOST_CC:-}" ]; then
    HOST_CC="$(command -v "clang-$NDK_CLANG_MAJOR" 2>/dev/null || command -v clang)"
fi
if [ -z "${HOST_CXX:-}" ]; then
    HOST_CXX="$(command -v "clang++-$NDK_CLANG_MAJOR" 2>/dev/null || command -v clang++)"
fi
HOST_AR="${HOST_AR:-$(command -v llvm-ar || command -v llvm-ar-18 || echo ar)}"
HOST_RANLIB="${HOST_RANLIB:-$(command -v llvm-ranlib || command -v llvm-ranlib-18 || echo ranlib)}"

export ANDROID_SDK_ROOT ANDROID_NDK_HOME ANDROID_API ANDROID_SYSROOT NDK_PREBUILT
export NDK_RUNTIME_DIR NDK_RESOURCE_DIR NDK_CLANG_MAJOR HOST_CC HOST_CXX HOST_AR HOST_RANLIB

# Rust triple -> (clang target, jniLibs ABI dir)
# arch subdirectory of the NDK clang runtime dir, which is named per LLVM arch and
# does not always match the Rust triple's first component.
android_runtime_arch() {
    case "$1" in
        aarch64-linux-android) echo "aarch64" ;;
        x86_64-linux-android)  echo "x86_64" ;;
        armv7-linux-androideabi) echo "arm" ;;
        i686-linux-android)    echo "i386" ;;
        *) echo "unknown rust target $1" >&2; return 1 ;;
    esac
}

android_clang_target() {
    case "$1" in
        aarch64-linux-android) echo "aarch64-linux-android$ANDROID_API" ;;
        x86_64-linux-android)  echo "x86_64-linux-android$ANDROID_API" ;;
        armv7-linux-androideabi) echo "armv7a-linux-androideabi$ANDROID_API" ;;
        i686-linux-android)    echo "i686-linux-android$ANDROID_API" ;;
        *) echo "unknown rust target $1" >&2; return 1 ;;
    esac
}

android_abi() {
    case "$1" in
        aarch64-linux-android) echo "arm64-v8a" ;;
        x86_64-linux-android)  echo "x86_64" ;;
        armv7-linux-androideabi) echo "armeabi-v7a" ;;
        i686-linux-android)    echo "x86" ;;
        *) echo "unknown rust target $1" >&2; return 1 ;;
    esac
}

# Export the per-target cargo/cc variables for one Rust triple. Per-target env
# (CARGO_TARGET_<TRIPLE>_*) rather than a global RUSTFLAGS, so several targets can
# be built in one script run without clobbering each other.
android_cargo_env() {
    local triple="$1" ct upper arch
    ct="$(android_clang_target "$triple")" || return 1
    arch="$(android_runtime_arch "$triple")" || return 1
    upper="$(echo "$triple" | tr 'a-z-' 'A-Z_')"
    local rtdir="$NDK_RUNTIME_DIR/$arch"
    local flags="--target=$ct --sysroot=$ANDROID_SYSROOT"

    export "CARGO_TARGET_${upper}_LINKER=$HOST_CC"
    export "CARGO_TARGET_${upper}_RUSTFLAGS=-Clink-arg=--target=$ct -Clink-arg=--sysroot=$ANDROID_SYSROOT -Clink-arg=-L$rtdir -Clink-arg=-L$NDK_RUNTIME_DIR"
    # the `cc` crate (libsqlite3-sys builds SQLite from source) reads these
    local lower="${triple//-/_}"
    export "CC_${lower}=$HOST_CC"
    export "CXX_${lower}=$HOST_CXX"
    export "AR_${lower}=$HOST_AR"
    export "RANLIB_${lower}=$HOST_RANLIB"
    export "CFLAGS_${lower}=$flags"
    export "CXXFLAGS_${lower}=$flags"
}

# ── CMake shim NDK ───────────────────────────────────────────────────────────
# CMake's own Android support (used by PyTorch's build, and by AGP's externalNativeBuild)
# derives the toolchain from CMAKE_ANDROID_NDK and will NOT honour a -DCMAKE_C_COMPILER
# override. Two things go wrong on an aarch64 Linux host:
#
#   1. Android-Determine.cmake maps a non-x86_64 Linux host to the tag "linux-x86", finds
#      no toolchains/llvm/prebuilt/linux-x86/sysroot, concludes the NDK is pre-unified and
#      fails looking for the long-removed platforms/android-NN/arch-ARCH layout.
#   2. Even once found, it insists on the NDK's own clang, which is an x86_64 binary and
#      would run every compile under qemu.
#
# So we materialise a shadow NDK: everything symlinked to the real one, except the
# toolchain bin/, where clang/clang++ and the LLVM binutils become the HOST's native
# tools. CMake then picks "our" compiler by its own rules and it happens to be native.
#
# Echoes the shim path. Cheap and idempotent — safe to call on every build.
android_cmake_ndk() {
    local shim="${ANDROID_NDK_SHIM:-${1:-}}"
    [ -n "$shim" ] || { echo "android_cmake_ndk needs a destination path" >&2; return 1; }
    local stamp="$shim/.stamp"
    if [ -f "$stamp" ] && [ "$(cat "$stamp" 2>/dev/null)" = "$ANDROID_NDK_HOME" ]; then
        echo "$shim"; return 0
    fi

    local resdir
    resdir="$(android_merged_resource_dir "$(dirname "$shim")/clang-resource")" || return 1
    SHIM_RESOURCE_DIR="$resdir"

    rm -rf "$shim"
    mkdir -p "$shim/toolchains/llvm/prebuilt"
    local e="" n=""
    for e in "$ANDROID_NDK_HOME"/*; do
        n="$(basename "$e")"
        [ "$n" = "toolchains" ] && continue
        ln -s "$e" "$shim/$n"
    done

    # Both tag names: "linux-x86" is what CMake looks for here, "linux-x86_64" is what
    # anything else (ndk-build, AGP) expects, and they must be the same tree.
    local tag="" real="$NDK_PREBUILT" dst=""
    for tag in linux-x86 linux-x86_64; do
        dst="$shim/toolchains/llvm/prebuilt/$tag"
        mkdir -p "$dst/bin"
        for e in "$real"/*; do
            n="$(basename "$e")"
            [ "$n" = "bin" ] && continue
            ln -s "$e" "$dst/$n"
        done
        # Start from the real bin so nothing goes missing, then shadow the hot tools.
        for e in "$real"/bin/*; do
            ln -s "$e" "$dst/bin/$(basename "$e")" 2>/dev/null || true
        done
        _android_shim_tool "$dst/bin/clang"   "$HOST_CC"
        _android_shim_tool "$dst/bin/clang++" "$HOST_CXX"
        local tool="" hosttool=""
        for tool in llvm-ar llvm-ranlib llvm-strip llvm-nm llvm-objcopy llvm-readelf \
                    llvm-as llvm-link llvm-dwp ld.lld; do
            hosttool="$(command -v "$tool" 2>/dev/null || command -v "$tool-18" 2>/dev/null || true)"
            [ -n "$hosttool" ] && ln -sf "$hosttool" "$dst/bin/$tool"
        done
    done

    echo "$ANDROID_NDK_HOME" > "$stamp"
    echo "$shim"
}

# The clang resource directory the wrapper hands to the host compiler.
#
# It cannot simply be the NDK's: Google's clang is a fork, and its arm_neon.h calls
# builtins (e.g. __builtin_neon_vext_f16) that upstream clang of the same major version
# does not have — XNNPACK's fp16 microkernels fail to compile against it. Nor can it be
# the host's alone: a distro clang ships no compiler-rt builtins or libunwind for
# Android targets, so every link fails.
#
# So it is a merge: the HOST compiler's own headers (which must match the compiler) and
# the NDK's runtime libraries (which are ABI-stable and target-specific). Echoes its path.
android_merged_resource_dir() {
    local dest="${1:-}"
    [ -n "$dest" ] || { echo "android_merged_resource_dir needs a destination" >&2; return 1; }
    local hostres
    hostres="$("$HOST_CC" -print-resource-dir 2>/dev/null)"
    [ -d "$hostres" ] || { echo "cannot locate the resource dir of $HOST_CC" >&2; return 1; }

    local stamp="$dest/.stamp"
    if [ -f "$stamp" ] && [ "$(cat "$stamp" 2>/dev/null)" = "$hostres|$NDK_RESOURCE_DIR" ]; then
        echo "$dest"; return 0
    fi

    rm -rf "$dest"
    mkdir -p "$dest/lib"
    local e="" n=""
    for e in "$hostres"/*; do
        n="$(basename "$e")"
        [ "$n" = "lib" ] && continue
        ln -s "$e" "$dest/$n"
    done
    # Host's lib/ entries first, then let the NDK's target runtimes win.
    for e in "$hostres"/lib/*; do
        n="$(basename "$e")"
        [ "$n" = "linux" ] && continue
        ln -s "$e" "$dest/lib/$n"
    done
    ln -s "$NDK_RESOURCE_DIR/lib/linux" "$dest/lib/linux"

    echo "$hostres|$NDK_RESOURCE_DIR" > "$stamp"
    echo "$dest"
}

# A wrapper that execs the host compiler as if it were the NDK's.
#
# CMake passes --target but NOT --sysroot: the NDK's clang infers the sysroot (and its
# resource dir) from its own location on disk, which a host compiler obviously cannot do.
# So the wrapper supplies both. `-resource-dir` is the important one — it is where
# compiler-rt's builtins, libunwind and the intrinsic headers live, and it is why
# HOST_CC is chosen to match the NDK's clang major version.
#
# -rtlib/-unwindlib restore the NDK driver's defaults: a distro clang targeting Android
# still reaches for libgcc, which no NDK has shipped for years. -Qunused-arguments keeps
# those two from tripping -Werror on compile-only invocations (the NDK passes it too).
#
# The resource dir is the merged one described above, NOT the NDK's.
_android_shim_tool() {
    # NB: not named `path` — in zsh that is tied to the PATH array and assigning it
    # would wipe PATH for the rest of the function.
    local dest="$1" hostcc="$2"
    local resdir="${SHIM_RESOURCE_DIR:-$NDK_RESOURCE_DIR}"
    rm -f "$dest"
    cat > "$dest" <<WRAP
#!/bin/sh
# Generated by android_cmake_ndk (apps/android/android-env.sh). Do not edit.
exec "$hostcc" --sysroot="$ANDROID_SYSROOT" -resource-dir="$resdir" \\
    -rtlib=compiler-rt --unwindlib=libunwind -Qunused-arguments "\$@"
WRAP
    chmod +x "$dest"
}
