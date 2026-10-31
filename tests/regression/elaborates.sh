#!/usr/bin/env bash
# Property test: the generated Lean for <crate> must elaborate.
#
# Fails only on output containing "error" -- "declaration uses sorry" is a warning. Keyed on the
# generated file, not aeneas's exit status: aeneas exits non-zero whenever an item is reported.
#
# Usage: elaborates.sh <crate-dir-name>
set -uo pipefail
cd "$(dirname "$0")" || exit 2
crate=${1:?usage: elaborates.sh <crate-dir>}
mod=$(echo "$crate" | tr '-' '_')

AENEAS=${AENEAS:-$HOME/src/aeneas/src/_build/default/main.exe}
CHARON=${CHARON:-$HOME/src/aeneas/charon/bin/charon}
LEAN_PKG=${LEAN_PKG:-$HOME/.local/aeneas/backends/lean}
CHARON_TARGET=${CHARON_TARGET_DIR:-$HOME/.cache/ferrosa-lean-extract/target}
mkdir -p "$CHARON_TARGET"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp -r "$crate/." "$work/"
cd "$work" || exit 2

CARGO_TARGET_DIR="$CHARON_TARGET" "$CHARON" cargo --preset=aeneas \
  --start-from "$mod::*" -- --lib > charon.log 2>&1
llbc=$(ls *.llbc 2>/dev/null | head -1)
[ -n "$llbc" ] || { echo "FAIL: charon produced no .llbc"; tail -5 charon.log; exit 1; }

"$AENEAS" -backend lean "$llbc" > aeneas.log 2>&1
lean=$(ls *.lean 2>/dev/null | head -1)
[ -n "$lean" ] || { echo "FAIL: aeneas produced no .lean"; tail -5 aeneas.log; exit 1; }

out=$(cd "$LEAN_PKG" && LEAN_NUM_THREADS=2 lake env lean "$work/$lean" 2>&1)
if echo "$out" | grep -q "error"; then
  echo "FAIL: generated Lean does not elaborate ($crate)"
  echo "$out" | head -6
  exit 1
fi
echo "PASS: generated Lean elaborates ($crate)"
