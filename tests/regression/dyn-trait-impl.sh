#!/usr/bin/env bash
# RED/GREEN regression test: a trait impl whose method failed to translate must not be
# printed as `:= { sorry }`. Lean reads that as singleton notation and fails with
#   failed to synthesize instance of type class Singleton ?m.2 (<impl type>)
# which names neither the implementation nor the cause. The assertion is that the generated
# file elaborates, so any output Lean accepts passes.
#
# Note: aeneas exits non-zero when the crate has translation errors, and this crate does.
# The test therefore keys on the generated file, not on aeneas's status.
set -uo pipefail
cd "$(dirname "$0")" || exit 2

AENEAS=${AENEAS:-$HOME/src/aeneas/src/_build/default/main.exe}
CHARON=${CHARON:-$HOME/src/aeneas/charon/bin/charon}
LEAN_PKG=${LEAN_PKG:-$HOME/.local/aeneas/backends/lean}
export CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-$HOME/.local/share/cargo-target}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp -r repro-dyn-error/. "$work/"
cd "$work" || exit 2

"$CHARON" cargo --preset=aeneas --start-from 'repro_dyn_error::*' -- --lib > charon.log 2>&1
llbc=$(ls *.llbc 2>/dev/null | head -1)
[ -n "$llbc" ] || { echo "FAIL: charon produced no .llbc"; tail -5 charon.log; exit 1; }

"$AENEAS" -backend lean "$llbc" > aeneas.log 2>&1
lean=$(ls *.lean 2>/dev/null | head -1)
[ -n "$lean" ] || { echo "FAIL: aeneas produced no .lean"; tail -5 aeneas.log; exit 1; }

out=$(cd "$LEAN_PKG" && LEAN_NUM_THREADS=2 lake env lean "$work/$lean" 2>&1)
# Warnings (e.g. "declaration uses sorry") are expected; only errors fail the test.
if echo "$out" | grep -q "error"; then
  echo "FAIL: generated Lean does not elaborate"
  echo "$out" | head -8
  echo "--- emitted impl ---"
  grep -n -A3 "rust_trait_impl" "$lean" | head -10
  exit 1
fi
echo "PASS: generated Lean elaborates"
