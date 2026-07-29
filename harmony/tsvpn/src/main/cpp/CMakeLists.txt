cmake_minimum_required(VERSION 3.16)
project(tsbridge)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(NATIVE_ROOT ${CMAKE_CURRENT_SOURCE_DIR})
# Prebuilt Go core (built by ../../../../scripts/build-ohos.sh) lives in
# entry/libs/${OHOS_ARCH}/libtailscale_ohos.so. OHOS_ARCH is injected by the
# DevEco CMake toolchain (arm64-v8a for 64-bit arm).
if(NOT DEFINED OHOS_ARCH)
    set(OHOS_ARCH arm64-v8a)
endif()
set(LIBS_DIR ${NATIVE_ROOT}/../../../libs/${OHOS_ARCH})

add_library(tsbridge SHARED napi_init.cpp)

# NOTE: libtailscale_ohos.so is intentionally NOT linked here — it is loaded at
# runtime via dlopen(RTLD_GLOBAL) in napi_init.cpp (see the comment there about
# the Go cgo initial-exec TLS model vs. the OHOS musl loader). It is still
# packaged into the hap because it sits in entry/libs/${OHOS_ARCH}/.
target_link_libraries(tsbridge PUBLIC
    libace_napi.z.so
    libhilog_ndk.z.so)
