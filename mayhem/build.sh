#!/usr/bin/env bash
#
# mayhem/build.sh — build libarchive's fuzz harnesses (sanitized) AND its own test suite (normal flags).
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. Re-runnable and offline:
# every dependency (-dev packages) is baked into the image; nothing is fetched here.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`): an explicit EMPTY SANITIZER_FLAGS builds with no sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
FUZZ_SRC="$SRC/contrib/oss-fuzz"
FUZZ_BUILD="$SRC/mayhem/build-fuzz"
TEST_BUILD="$SRC/mayhem/build-test"

# Every harness upstream's contrib/oss-fuzz/oss-fuzz-build.sh builds.
HARNESSES=(
  libarchive_fuzzer libarchive_tar_fuzzer libarchive_zip_fuzzer libarchive_7zip_fuzzer
  libarchive_rar_fuzzer libarchive_rar5_fuzzer libarchive_xar_fuzzer libarchive_cab_fuzzer
  libarchive_lha_fuzzer libarchive_iso9660_fuzzer libarchive_cpio_fuzzer libarchive_warc_fuzzer
  libarchive_mtree_fuzzer libarchive_ar_fuzzer libarchive_filter_fuzzer libarchive_entry_fuzzer
  libarchive_write_fuzzer libarchive_linkify_fuzzer libarchive_match_fuzzer
  libarchive_encryption_fuzzer libarchive_read_disk_fuzzer libarchive_write_disk_fuzzer
  libarchive_seek_fuzzer libarchive_string_fuzzer libarchive_roundtrip_fuzzer
)

# 1) The project itself, sanitized + instrumented for coverage (fuzzer-no-link) + DWARF 3.
#    DONT_FAIL_ON_CRC_ERROR is upstream's own "for fuzzing" switch: checksum gates would otherwise
#    reject nearly every mutated archive before the parsers run.
#    ASan's leak check would fail cmake's try_compile probes, so it is off for configure only.
ASAN_OPTIONS=detect_leaks=0 cmake -S "$SRC" -B "$FUZZ_BUILD" -G Ninja \
  -DCMAKE_BUILD_TYPE=None -DCMAKE_C_COMPILER="$CC" \
  -DCMAKE_C_FLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link -O1 $DEBUG_FLAGS" \
  -DBUILD_SHARED_LIBS=OFF -DENABLE_TEST=OFF -DENABLE_TAR=OFF -DENABLE_CPIO=OFF \
  -DENABLE_CAT=OFF -DENABLE_UNZIP=OFF -DENABLE_INSTALL=OFF -DENABLE_LZO=ON \
  -DDONT_FAIL_ON_CRC_ERROR=ON >/dev/null
cmake --build "$FUZZ_BUILD" -j"$MAYHEM_JOBS"

# Link line for the static lib: what libarchive's own pkg-config file lists as private deps.
PRIV_LIBS="$(sed -n 's/^Libs.private: *//p' "$FUZZ_BUILD/build/pkgconfig/libarchive.pc")"
LIBARCHIVE_A="$FUZZ_BUILD/libarchive/libarchive.a"
INCS="-I$SRC/libarchive -I$FUZZ_SRC -DLIBARCHIVE_STATIC"

# 2) Harnesses: a libFuzzer binary and a run-once -standalone reproducer each; LSan switched off at build time.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$FUZZ_BUILD/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$FUZZ_BUILD/standalone_main.o"
build_harness() {
  local h="$1"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS -O1 $INCS $LIB_FUZZING_ENGINE "$FUZZ_SRC/$h.cc" \
      "$FUZZ_BUILD/lsan_off.o" "$LIBARCHIVE_A" $PRIV_LIBS -o "$SRC/$h"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS -O1 $INCS "$FUZZ_SRC/$h.cc" "$FUZZ_BUILD/standalone_main.o" \
      "$FUZZ_BUILD/lsan_off.o" "$LIBARCHIVE_A" $PRIV_LIBS -o "$SRC/$h-standalone"
}
export -f build_harness
export FUZZ_SRC FUZZ_BUILD LIBARCHIVE_A PRIV_LIBS INCS SRC
printf '%s\n' "${HARNESSES[@]}" | xargs -P "$MAYHEM_JOBS" -I{} bash -c 'build_harness {}'

# 3) The project's own test suite, normal flags (no sanitizers, no -gdwarf-3), for mayhem/test.sh.
cmake -S "$SRC" -B "$TEST_BUILD" -G Ninja \
  -DCMAKE_BUILD_TYPE=None -DCMAKE_C_COMPILER="$CC" \
  -DCMAKE_C_FLAGS="-O1 $COVERAGE_FLAGS" -DCMAKE_EXE_LINKER_FLAGS="$COVERAGE_FLAGS" \
  -DCMAKE_SHARED_LINKER_FLAGS="$COVERAGE_FLAGS" \
  -DENABLE_TEST=ON -DENABLE_INSTALL=OFF -DENABLE_LZO=ON >/dev/null
cmake --build "$TEST_BUILD" -j"$MAYHEM_JOBS"
