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
# Resolve before the cd below, so the case's own files are still reachable by their given name.
crate=$(realpath "$crate")
mod=$(basename "$crate" | tr '-' '_')

AENEAS=${AENEAS:-$HOME/src/aeneas/src/_build/default/main.exe}
CHARON=${CHARON:-$HOME/src/aeneas/charon/bin/charon}
CHARON_TARGET=${CHARON_TARGET_DIR:-$HOME/.cache/charon-target}
mkdir -p "$CHARON_TARGET"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# A crate may need extra Charon arguments (for instance --opaque=... to keep a type out of the
# translation). One argument per word, so keep the file free of quoting.
extra_args=()
if [ -f "$crate/charon-args" ]; then
  read -r -a extra_args < "$crate/charon-args"
fi

# A crate is normally built through Cargo. A folder may instead carry a `charon-mode` file whose
# first word is `rustc`, followed by the file to compile: some constructs only reach the failing
# path when Charon compiles a single file, and a Cargo build would quietly take another one.
charon_mode=cargo
charon_src=
if [ -f "$crate/charon-mode" ]; then
  read -r charon_mode charon_src < "$crate/charon-mode"
fi

cp -r "$crate/." "$work/"
# A case built as a workspace with a path dependency (the shape a real dependency has) keeps those
# declarations external; charon takes no --manifest-path, so it has to run inside the member, and the
# module pattern must name the member. Naming the directory instead produced
# `--start-from trait_order::*`, which charon reports as "does not correspond to any item" and then as
# a compile failure -- the case could never run.
workdir="$work"
if [ -d "$work/user" ]; then
  workdir="$work/user"
  mod=user
fi
cd "$workdir" || exit 2

if [ "$charon_mode" = rustc ]; then
  CHARON_TARGET_DIR="$CHARON_TARGET" "$CHARON" rustc --preset=aeneas \
    "${extra_args[@]}" -- --crate-type=lib "$charon_src" > charon.log 2>&1
else
  CHARON_TARGET_DIR="$CHARON_TARGET" "$CHARON" cargo --preset=aeneas \
    --start-from "$mod::*" "${extra_args[@]}" -- --lib > charon.log 2>&1
fi
# Charon writes the .llbc at the workspace root even when it is run inside a member, so look in both.
llbc=$(ls *.llbc "$work"/*.llbc 2>/dev/null | head -1)
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
