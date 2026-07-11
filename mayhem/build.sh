#!/usr/bin/env bash
#
# boost-beast/mayhem/build.sh — build Boost.Beast's OSS-Fuzz harnesses as sanitized libFuzzer
# targets (+ standalone reproducers).
#
# The fuzzed surface is Beast's HTTP / WebSocket message PARSERS, driven over a test::stream that
# replays attacker-controlled bytes (libs/beast/test/fuzz/*.cpp, header-only Beast):
#   http_request      — http::request_parser<dynamic_body>::read over the input bytes
#                       (request line + headers + chunked/identity body parsing).
#   http_response     — http::response_parser<dynamic_body>::read, with an on_chunk_header callback
#                       that also parses chunk EXTENSIONS (http::chunk_extensions::parse).
#   websocket_server  — websocket::stream::accept (the opening HTTP handshake parse) then read/write
#                       of one WebSocket frame, with permessage-deflate toggled by the input length.
# The input is the raw wire bytes (an HTTP request/response, or a WS handshake+frame), NOT a struct.
#
# Beast is a header-only Boost submodule library; its harnesses live in the beast checkout but its
# (non-beast) dependency headers do not. Like OSS-Fuzz's build.sh we assemble a Boost superproject:
# clone boostorg/boost, REPLACE libs/beast with OUR checkout (so the fuzzed beast code is exactly the
# committed version), pull beast's matching dependency submodules via boostdep, and materialise the
# combined `boost/` header tree with `b2 headers`. We then compile the harnesses header-only against
# that tree with $SANITIZER_FLAGS so the beast parser code (not just the harness) is instrumented.
#
# Build contract comes from the org base ENV (CC/CXX/SANITIZER_FLAGS/LIB_FUZZING_ENGINE/SRC/$OUT/
# STANDALONE_FUZZ_MAIN). One libFuzzer binary per harness in $OUT (/mayhem) + a -standalone reproducer.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${SRC:=$(cd "$(dirname "$0")/.." && pwd)}"
: "${OUT:=/mayhem}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE SRC OUT MAYHEM_JOBS

# Where the beast checkout (our source) lives, and the harness/standalone driver.
BEAST="$SRC"
FUZZ_DIR="$BEAST/libs/beast/test/fuzz"            # path AFTER we graft beast into the superproject
HARNESS_SRC="$BEAST/test/fuzz"                     # harnesses as they sit in the beast checkout
# Use OUR C++ standalone driver, not the base's $STANDALONE_FUZZ_MAIN (a C file: its
# LLVMFuzzerTestOneInput has C linkage, which won't resolve against the C++-compiled harness).
STANDALONE_MAIN="$SRC/mayhem/harnesses/standalone_main.cpp"
HARNESSES="http_request http_response websocket_server"

# ── 1) Assemble the Boost superproject with OUR beast grafted in ───────────────────────────────────
# Pinned to a recent master superproject; depinst then pulls dependency versions that match beast.
SUPER="$SRC/mayhem-boost"
if [ ! -f "$SUPER/boost/beast/version.hpp" ]; then
  rm -rf "$SUPER"
  git clone --depth 1 https://github.com/boostorg/boost.git "$SUPER"
  git -C "$SUPER" submodule update --init --depth 1 tools/boostdep
  # Graft OUR beast checkout in place of the submodule (drop .git so it's a plain tree).
  # Copy via tar so we can EXCLUDE the work tree ($SUPER lives under $SRC in the image, so a plain
  # `cp -r $SRC ...` would recurse into itself) and the .git history.
  rm -rf "$SUPER/libs/beast"
  mkdir -p "$SUPER/libs/beast"
  tar -C "$BEAST" \
      --exclude='./.git' --exclude='./mayhem-boost' --exclude='./mayhem-build' \
      --exclude='./mayhem-tests' -cf - . | tar -C "$SUPER/libs/beast" -xf -
  # Pull the (non-beast) dependency submodules beast needs, then build the combined header tree.
  # depinst + b2 must run from the superproject root.
  ( cd "$SUPER" \
      && python3 tools/boostdep/depinst/depinst.py --git_args "--jobs ${MAYHEM_JOBS} --depth 1" beast \
      && ./bootstrap.sh \
      && ./b2 headers )
fi
INC="-I$SUPER"
FUZZ_DIR="$SUPER/libs/beast/test/fuzz"

# ── 2) Build each harness twice: libFuzzer (-> $OUT/<name>) + standalone reproducer ────────────────
# Beast's parsers are header-only, so each harness is a single self-contained TU; no library to link.
for harness in $HARNESSES; do
  src="$FUZZ_DIR/$harness.cpp"
  [ -f "$src" ] || { echo "ERROR: harness source missing: $src" >&2; exit 1; }

  # libFuzzer target -> $OUT/<name>
  $CXX -std=c++17 $SANITIZER_FLAGS $DEBUG_FLAGS -pthread $INC \
      "$src" $LIB_FUZZING_ENGINE \
      -o "$OUT/$harness"

  # standalone reproducer (no libFuzzer runtime) -> $OUT/<name>-standalone
  $CXX -std=c++17 $SANITIZER_FLAGS $DEBUG_FLAGS -pthread $INC \
      "$src" "$STANDALONE_MAIN" \
      -o "$OUT/$harness-standalone"

  echo "built $harness (+ standalone)"
done

echo "build.sh complete:"
for harness in $HARNESSES; do
  ls -la "$OUT/$harness" "$OUT/$harness-standalone" 2>&1 || true
done
