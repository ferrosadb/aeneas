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

AENEAS=${AENEAS:-$HOME/src/aeneas/src/_build/default/main.exe}
CHARON=${CHARON:-$HOME/src/aeneas/charon/bin/charon}
LEAN_PKG=${LEAN_PKG:-$HOME/.local/aeneas/backends/lean}
CHARON_TARGET=${CHARON_TARGET_DIR:-$HOME/.cache/ferrosa-lean-extract/target}
mkdir -p "$CHARON_TARGET"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp -r "$crate/." "$work/"
# A crate pulling traits from a path dependency keeps those declarations external -- the shape a
# real dependency (serde) has. Such a crate is a workspace, and the work happens in its `user`
# member; charon takes no --manifest-path, so it must be run from inside that directory.
workdir="$work"
[ -d "$work/user" ] && workdir="$work/user"
cd "$workdir" || exit 2
mod=$(basename "$workdir" | tr '-' '_')

CARGO_TARGET_DIR="$CHARON_TARGET" "$CHARON" cargo --preset=aeneas \
  --start-from "$mod::*" -- --lib > charon.log 2>&1
llbc=$(ls *.llbc "$work"/*.llbc 2>/dev/null | head -1)
[ -n "$llbc" ] || { echo "FAIL: charon produced no .llbc"; grep -E "^error" -A2 charon.log | head -6; exit 1; }

"$AENEAS" -backend lean "$llbc" > aeneas.log 2>&1
lean=$(realpath "$(ls "$work"/*.lean *.lean 2>/dev/null | head -1)" 2>/dev/null)
[ -n "$lean" ] || { echo "FAIL: aeneas produced no .lean"; tail -5 aeneas.log; exit 1; }

out=$(cd "$LEAN_PKG" && LEAN_NUM_THREADS=2 lake env lean "$lean" 2>&1)
if echo "$out" | grep -q "error"; then
  echo "FAIL: generated Lean does not elaborate ($crate)"
  echo "$out" | head -6
  exit 1
fi
echo "PASS: generated Lean elaborates ($crate)"
