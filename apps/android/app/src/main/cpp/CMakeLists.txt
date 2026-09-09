# The JNI torch bridge, built only for the `full` product flavor.
#
# LibTorch comes from spike/build_libtorch_android.sh, which builds torch 2.9.0 with the
# lite interpreter for each ABI into apps/android/libtorch-android/<abi>/. That is the
# same runtime apps/ios builds, which is what makes the two clients bit-exact on the same
# .ptl files. Both the archives and the models are gitignored, exactly as on iOS.
cmake_minimum_required(VERSION 3.22)
project(oura_torch CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# `externalNativeBuild.path` is module-wide — AGP has no per-flavor form — so the `lite`
# flavor would configure this file too. It passes no OURA_BUILD_TORCH, and defines no
# targets, which is exactly right: lite must build with no LibTorch present at all.
if(NOT OURA_BUILD_TORCH)
    message(STATUS "oura: OURA_BUILD_TORCH is off (lite flavor) — no native targets")
    return()
endif()

set(LIBTORCH "${CMAKE_CURRENT_SOURCE_DIR}/../../../../libtorch-android/${ANDROID_ABI}")
if(NOT EXISTS "${LIBTORCH}/include")
    message(FATAL_ERROR
        "LibTorch for ${ANDROID_ABI} not found at ${LIBTORCH}.\n"
        "Build it first:  apps/android/spike/build_libtorch_android.sh ${ANDROID_ABI}\n"
        "Or build the `lite` flavor, which needs no models at all.")
endif()

add_library(oura_torch SHARED torch_bridge.cpp)

target_include_directories(oura_torch PRIVATE
    "${LIBTORCH}/include"
    "${LIBTORCH}/include/torch/csrc/api/include")

# Which archives exist depends on the configure flags (USE_BLAS=OFF drops eigen_blas, this
# NDK's cpuinfo needs no clog, and so on), so take what the install actually produced
# rather than a hardcoded list that silently rots.
set(_oura_torch_libs torch c10 XNNPACK microkernels-prod pthreadpool cpuinfo fmt kineto)
set(_oura_torch_found "")
foreach(lib IN LISTS _oura_torch_libs)
    if(EXISTS "${LIBTORCH}/lib/lib${lib}.a")
        list(APPEND _oura_torch_found "${LIBTORCH}/lib/lib${lib}.a")
    endif()
endforeach()
if(NOT EXISTS "${LIBTORCH}/lib/libtorch_cpu.a")
    message(FATAL_ERROR "libtorch_cpu.a missing from ${LIBTORCH}/lib — the build did not finish")
endif()

# torch_cpu carries the operator registrations the lite interpreter looks up by name at
# runtime. They look unreferenced to the linker, so without --whole-archive they are
# dropped and the models load and then fail with "unknown builtin op". The rest are
# mutually recursive, hence the link group.
target_link_libraries(oura_torch
    -Wl,--whole-archive
    "${LIBTORCH}/lib/libtorch_cpu.a"
    -Wl,--no-whole-archive
    -Wl,--start-group
    ${_oura_torch_found}
    -Wl,--end-group
    android
    log)
