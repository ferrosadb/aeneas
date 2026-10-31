#!/usr/bin/env bash
# RED/GREEN regression test: an unsupported construct must not abort the run.
#
# Several constructs are marked "Unimplemented" inside the translator and raise CFailure that
# nothing catches, so aeneas dies with a stack trace and writes no output. The behaviour under
# test: the item is reported and the run continues.
#
# Usage: no-uncaught-crash.sh [crate-dir-name]      (default: assoc-type-bound)
set -uo pipefail
cd "$(dirname "$0")" || exit 2

crate=${1:-assoc-type-bound}
mod=$(echo "$crate" | tr '-' '_')

AENEAS=${AENEAS:-$HOME/src/aeneas/src/_build/default/main.exe}
CHARON=${CHARON:-$HOME/src/aeneas/charon/bin/charon}
CHARON_TARGET=${CHARON_TARGET_DIR:-$HOME/.cache/ferrosa-lean-extract/target}
mkdir -p "$CHARON_TARGET"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp -r "$crate/." "$work/"
cd "$work" || exit 2

CHARON_TARGET_DIR="$CHARON_TARGET" "$CHARON" cargo --preset=aeneas \
  --start-from "$mod::*" -- --lib > charon.log 2>&1
llbc=$(ls *.llbc 2>/dev/null | head -1)
[ -n "$llbc" ] || { echo "FAIL: charon produced no .llbc"; tail -5 charon.log; exit 1; }

out=$("$AENEAS" -backend lean "$llbc" 2>&1)
status=$?

if echo "$out" | grep -q "Fatal error: exception"; then
  echo "FAIL: aeneas aborted with an uncaught exception"
  echo "$out" | grep -A3 "Fatal error: exception" | head -5
  exit 1
fi

# The contract is "never fatal": either the crate is modelled, or the run reaches the end and
# leaves a partial file plus reported errors. An exit status alone means nothing here, because
# aeneas exits non-zero whenever any item is reported.
if ls *.lean >/dev/null 2>&1; then
  echo "PASS: aeneas reported the item and kept going ($crate)"
  echo "$out" | grep -aF '[Error]' | head -3
  exit 0
fi

if [ $status -eq 0 ]; then
  echo "PASS: aeneas completed and modelled $crate"
  exit 0
fi

echo "FAIL: no output produced and no error reported (exit $status)"
echo "$out" | tr '\r' '\n' | grep -av "^\s*$" | tail -8
exit 1
