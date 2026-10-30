#!/usr/bin/env bash
#
# mayhem/build.sh — build vcpkg-tool's three libFuzzer harnesses (+ standalone reproducers) with ASan+UBSan,
# and the Catch2 unit-test binary (vcpkg-test) with normal flags. Runs in /mayhem as `mayhem`; air-gapped
# on re-run: fmt / CMakeRC / curl headers come from the tarballs the Dockerfile cached in /opt/toolchains.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

DEPS=/opt/toolchains/vcpkg-deps
DEP_ARGS=(
  -DVCPKG_FMT_URL="$DEPS/fmt-12.1.0.tar.gz"
  -DVCPKG_CMAKERC_URL="$DEPS/cmrc-2.0.1.tar.gz"
  -DVCPKG_LIBCURL_DLSYM_UPDATED_HEADERS=OFF
  -DVCPKG_LIBCURL_URL="$DEPS/curl-7.29.0.tar.gz"
  -DFETCHCONTENT_QUIET=ON
)
HARNESSES=(vcpkg-fuzz-json vcpkg-fuzz-platform-expressions vcpkg-fuzz-utf8-decoder)
FUZZ_BUILD="$SRC/build-fuzz"

# A CMake build dir configured under another compiler path (the image build runs through the ccache
# masquerade dir, a re-run does not) makes CMake discard its cache and the -D options with it, leaving
# the fuzz targets undefined. Start from clean build dirs so every run configures from scratch.
rm -rf build-tests build-fuzz

# 1) Tests first, with the project's NORMAL flags (separate build dir): test.sh only runs the result.
cmake -S . -B build-tests -G Ninja -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DBUILD_TESTING=ON -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$COVERAGE_FLAGS" "${DEP_ARGS[@]}"
cmake --build build-tests -j"$MAYHEM_JOBS" --target vcpkg-test

# 2) Sanitized fuzz build. The project's own VCPKG_FUZZER_INSTRUMENTATION adds -fsanitize=address plus
#    sancov (inline-8bit-counters, trace-cmp, ...) to vcpkglib/fmt/locale-resources; on Linux it does not
#    link libFuzzer, so the engine goes in through the linker flags (configure-time try-compiles are
#    compile-only, as they would otherwise hit the engine's main). lsan_off.o disables LeakSanitizer.
mkdir -p "$FUZZ_BUILD"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$FUZZ_BUILD/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$FUZZ_BUILD/standalone_main.o"
cmake -S . -B build-fuzz -G Ninja -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
  -DBUILD_TESTING=OFF -DVCPKG_BUILD_FUZZING=ON -DVCPKG_FUZZER_INSTRUMENTATION=ON \
  -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE $FUZZ_BUILD/lsan_off.o" \
  "${DEP_ARGS[@]}"
cmake --build build-fuzz -j"$MAYHEM_JOBS" --target "${HARNESSES[@]}"

# 3) Install the fuzzers, and relink each against the run-once driver for a -standalone reproducer by
#    replaying its ninja link command with the engine swapped for standalone_main.o.
for h in "${HARNESSES[@]}"; do
  cp "$FUZZ_BUILD/$h" "/mayhem/$h"
  link="$(cd "$FUZZ_BUILD" && ninja -t commands "$h" | tail -n 1)"
  link="${link//" $LIB_FUZZING_ENGINE "/" $FUZZ_BUILD/standalone_main.o "}"
  link="${link//" -o $h "/" -o /mayhem/$h-standalone "}"
  (cd "$FUZZ_BUILD" && bash -c "$link")
done
