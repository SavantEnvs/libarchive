#!/usr/bin/env bash
#
# mayhem/test.sh — RUN libarchive's OWN functional test suites (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}


BIN="$SRC/mayhem/build-test/bin"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/libarchive-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
passed=0; failed=0; skipped=0

# 1) Known-answer probes through the dynamically linked tools: fixed fixture -> exact expected output.
#    Unconditional: a missing binary/fixture is a failure, never a skip. A neutered tool prints nothing.
kat() {  # kat <name> <expected> <command...>
  local name="$1" expected="$2" actual; shift 2
  actual="$("$@" 2>&1)" || true
  if [ "$actual" = "$expected" ]; then echo "KAT PASS: $name"; passed=$((passed+1))
  else echo "KAT FAIL: $name"; echo "  expected: $expected"; echo "  actual:   $actual"; failed=$((failed+1)); fi
}
T="$SRC/libarchive/test"
kat zip-listing $'dir/\nfile1\nfile2' "$BIN/bsdtar" -tf "$T/test_read_format_zip.zip.uu"
kat zip-extract-sha256 "fcf30b99ad097a0a48b1bfa6be7a1d0416105c28785fefbca0cf564cc84847cd" bash -c "'$BIN/bsdtar' -xOf '$T/test_read_format_zip.zip.uu' file1 | sha256sum | cut -d' ' -f1"
"$BIN/bsdcat" "$T/test_read_format_7zip_lzma1.7z.uu" > "$WORK/lzma1.7z" 2>/dev/null
kat 7zip-lzma-extract-sha256 "ea4bf20fca5f07682e1f15e766509ead7ff97c17ae51f33f226da7194c68fca2" bash -c "'$BIN/bsdtar' -xOf '$WORK/lzma1.7z' file1 | sha256sum | cut -d' ' -f1"
kat ar-listing $'yyytttsssaaafff.o\ngghh.o\nhhhhjjjjkkkkllll.o' bash -c "'$BIN/bsdtar' -tf '$T/test_read_format_ar.ar.uu' | head -3"
printf 'known content: libarchive roundtrip\n' > "$WORK/a.txt"
(cd "$WORK" && "$BIN/bsdtar" --format=pax -cf rt.tar a.txt)
kat tar-roundtrip-listing "a.txt" bash -c "cd '$WORK' && '$BIN/bsdtar' -tf rt.tar"
kat tar-roundtrip-content "known content: libarchive roundtrip" bash -c "cd '$WORK' && '$BIN/bsdtar' -xOf rt.tar a.txt"
kat tar-gzip-roundtrip "known content: libarchive roundtrip" bash -c "cd '$WORK' && '$BIN/bsdtar' -czf rt.tgz a.txt && '$BIN/bsdcat' rt.tgz | '$BIN/bsdtar' -xOf - a.txt"

# 2) The project's own suites. Parse their summary lines: a neutered/missing runner prints nothing
#    (no "Tests run"), which counts as a failure rather than a pass.
run_suite() {  # run_suite <runner> <refdir>
  local runner="$1" ref="$2" out run tf sk
  if [ ! -x "$BIN/$runner" ]; then echo "MISSING RUNNER: $runner (build.sh should have built it)"; failed=$((failed+1)); return; fi
  out="$WORK/$runner.out"
  (cd "$WORK" && "$BIN/$runner" -r "$SRC/$ref" > "$out" 2>&1)
  tail -8 "$out"
  run="$(sed -n 's/^ *Tests run: *//p' "$out" | tail -1)"
  tf="$(sed -n 's/^ *Tests failed: *//p' "$out" | tail -1)"
  sk="$(grep -c ' skipped$' "$out" || true)"
  if [ -z "$run" ] || [ -z "$tf" ]; then echo "NO SUMMARY from $runner"; failed=$((failed+1)); return; fi
  passed=$((passed + run - tf - sk)); failed=$((failed + tf)); skipped=$((skipped + sk))
}
run_suite libarchive_test libarchive/test
run_suite bsdtar_test tar/test
run_suite bsdcpio_test cpio/test
run_suite bsdcat_test cat/test
run_suite bsdunzip_test unzip/test

emit_ctrf "libarchive_test" "$passed" "$failed" "$skipped"
