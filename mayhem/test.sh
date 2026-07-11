#!/usr/bin/env bash
#
# boost-beast/mayhem/test.sh — functional oracle for Boost.Beast.
#
# PATH: a small SELF-CONTAINED golden oracle (mayhem/harnesses/oracle.cpp) over the SAME HTTP parse
# path the fuzzers drive (http::request_parser / http::response_parser over a test::stream). Beast's
# own unit suite needs the full b2 build system; instead we compile + run this additive oracle against
# the combined Boost header tree that mayhem/build.sh already assembled in $SRC/mayhem-boost. The
# oracle asserts byte-level parse results (method/target/version/header, chunked body decode, response
# status, AND that a malformed request line is rejected) — a no-op / exit(0) patch cannot pass.
#
# Compiled with NORMAL flags (env -u CFLAGS/CXXFLAGS/SANITIZER_FLAGS) so the oracle stays an honest
# correctness check, free of sanitizer/benign-UB noise. Emits a CTRF summary; exit 0 iff no failure.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=$(cd "$(dirname "$0")/.." && pwd)}"
: "${CXX:=clang++}"
cd "$SRC"

SUPER="$SRC/mayhem-boost"
ORACLE_SRC="$SRC/mayhem/harnesses/oracle.cpp"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
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

if [ ! -f "$SUPER/boost/beast/version.hpp" ]; then
  echo "missing Boost header tree at $SUPER — run mayhem/build.sh first" >&2
  emit_ctrf "beast-oracle" 0 1 0; exit 2
fi
if [ ! -f "$ORACLE_SRC" ]; then
  echo "missing oracle source $ORACLE_SRC" >&2
  emit_ctrf "beast-oracle" 0 1 0; exit 2
fi

echo "=== compiling beast oracle ==="
BIN="$SRC/mayhem-build/beast_oracle"
mkdir -p "$SRC/mayhem-build"
if ! env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
      "$CXX" -std=c++17 -O1 -pthread -I "$SUPER" "$ORACLE_SRC" -o "$BIN" 2>/tmp/beast_oracle_build.log; then
  echo "oracle failed to compile:" >&2; sed 's/^/    /' /tmp/beast_oracle_build.log >&2 | tail -20
  emit_ctrf "beast-oracle" 0 1 0; exit 2
fi

echo "=== running beast oracle ==="
out="$("$BIN" 2>&1)"; rc=$?
echo "$out"

PASSED=$(printf '%s\n' "$out" | grep -c '^PASS ')
FAILED=$(printf '%s\n' "$out" | grep -c '^FAIL ')
: "${PASSED:=0}" "${FAILED:=0}"

# If the oracle crashed (e.g. ASan/abort) before printing the summary, force a failure.
if ! printf '%s\n' "$out" | grep -q '^ORACLE_SUMMARY '; then
  echo "oracle did not print a summary (rc=$rc) — treating as failure" >&2
  [ "$FAILED" -eq 0 ] && FAILED=1
fi
[ "$rc" -eq 0 ] || { [ "$FAILED" -gt 0 ] || FAILED=1; }

emit_ctrf "beast-oracle" "$PASSED" "$FAILED"
