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
# Resolve now: the script cds into the work copy below, after which a relative case name no longer
# resolves -- which silently skipped `charon-mode` and sent a bare-.rs case down the cargo path.
crate=$(realpath "$crate")

AENEAS=${AENEAS:-$HOME/src/aeneas/src/_build/default/main.exe}
CHARON=${CHARON:-$HOME/src/aeneas/charon/bin/charon}
LEAN_PKG=${LEAN_PKG:-$HOME/.local/aeneas/backends/lean}
CHARON_TARGET=${CHARON_TARGET_DIR:-$HOME/.cache/charon-target}
mkdir -p "$CHARON_TARGET"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp -r "$crate/." "$work/"
# A crate pulling traits from a path dependency keeps those declarations external -- the shape a
# real dependency (serde) has. Such a crate is a workspace, and the work happens in its `user`
# member; charon takes no --manifest-path, so it must be run from inside that directory.
workdir="$work"
if [ -d "$work/user" ]; then
  workdir="$work/user"
  mod=user
else
  # The module pattern comes from the crate the case names, not from the temporary directory the
  # case was copied into: `--start-from tmp.XXXX::*` matches nothing and charon then fails.
  mod=$(basename "$crate" | tr '-' '_')
fi
cd "$workdir" || exit 2

# Extra Charon arguments and an optional `rustc` mode, same conventions as no-uncaught-crash.sh:
# some constructs only reach the failing path when Charon compiles a single file.
extra_args=()
if [ -f "$crate/charon-args" ]; then
  read -r -a extra_args < "$crate/charon-args"
fi
charon_mode=cargo
charon_src=
if [ -f "$crate/charon-mode" ]; then
  read -r charon_mode charon_src < "$crate/charon-mode"
fi

if [ "$charon_mode" = rustc ]; then
  CHARON_TARGET_DIR="$CHARON_TARGET" "$CHARON" rustc --preset=aeneas \
    "${extra_args[@]}" -- --crate-type=lib "$charon_src" > charon.log 2>&1
else
  CHARON_TARGET_DIR="$CHARON_TARGET" "$CHARON" cargo --preset=aeneas \
    --start-from "$mod::*" "${extra_args[@]}" -- --lib > charon.log 2>&1
fi
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
# An external declaration nobody models is a hole, not an assumption to be taken on trust: a `sorry`
# shows up in a completeness check, an `axiom` silently enlarges the trusted base.
if grep -q "^axiom " "$lean"; then
  echo "FAIL: generated Lean declares an axiom instead of a sorry hole ($crate)"
  grep -n "^axiom " "$lean" | head -3
  exit 1
fi
echo "PASS: generated Lean elaborates ($crate)"
