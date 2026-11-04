#!/usr/bin/env bash
# Check the generated Lean environment, not just matching output text: unused
# traits behind builtin models disappear, while a required opaque trait remains.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
: "${AENEAS:?set AENEAS to the compiler under test}"
: "${CHARON:?set CHARON to the pinned Charon compiler}"
: "${LEAN_PKG:?set LEAN_PKG to the matching built Lean backend}"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/nested" "$work/needed"
cp -R "$root/tests/regression/opaque-reachability" "$work/"
(
    cd "$root"
    "$CHARON" rustc --preset=aeneas --dest-file "$work/nested.llbc" -- \
        tests/src/nested-loop-exits.rs --crate-name=nested_loop_exits \
        --crate-type=rlib --edition=2021
)
"$AENEAS" "$work/nested.llbc" -backend lean -dest "$work/nested" -checks
test -f "$work/nested/Nested.lean"
awk '/^public import Aeneas$/ { print "public import Lean.Elab.Command" } { print }' \
    "$work/nested/Nested.lean" > "$work/guard.lean"
mv "$work/guard.lean" "$work/nested/Nested.lean"
cat >> "$work/nested/Nested.lean" <<'LEAN'

run_cmd do
  let env ← Lean.getEnv
  unless env.contains `nested_loop_exits.outer_break do
    throwError "nested-for regression was not extracted"
  if env.contains `nested_loop_exits.core.num.nonzero.ZeroablePrimitive then
    throwError "unused ZeroablePrimitive was emitted through a builtin model"
  if env.contains `nested_loop_exits.core.cmp.clamp.ClampBounds then
    throwError "unused ClampBounds was emitted through a builtin model"
LEAN
(
    cd "$work/opaque-reachability"
    "$CHARON" cargo --preset=aeneas --opaque=dep --dest-file "$work/needed.llbc" -- --lib
)
# Exercise the carried-but-untranslated trait boundary explicitly: retain the
# external declaration and its live local reference, excluding only its group
# from the translation set. This is the case the opaque fallback must support.
jq -e '[.translated.trait_decls[] | select(.item_meta.name[-1].Ident[0] == "Needed")] | length == 1' \
    "$work/needed.llbc" > /dev/null
jq '(.translated.trait_decls[] | select(.item_meta.name[-1].Ident[0] == "Needed") | .def_id) as $id
    | .translated.ordered_decls |= map(select(.TraitDecl.NonRec != $id))' \
    "$work/needed.llbc" > "$work/needed-filtered.llbc"
# Keep the LLBC basename: it determines the generated module filename.
mv "$work/needed-filtered.llbc" "$work/needed.llbc"
"$AENEAS" "$work/needed.llbc" -backend lean -dest "$work/needed" -checks
test -f "$work/needed/Needed.lean"
awk '/^public import Aeneas$/ { print "public import Lean.Elab.Command" } { print }' \
    "$work/needed/Needed.lean" > "$work/guard.lean"
mv "$work/guard.lean" "$work/needed/Needed.lean"
cat >> "$work/needed/Needed.lean" <<'LEAN'

run_cmd do
  let env ← Lean.getEnv
  unless env.contains `opaque_reachability.preserve do
    throwError "required-trait regression was not extracted"
  unless env.contains `opaque_reachability.dep.Needed do
    throwError "genuinely referenced opaque Needed was removed"
LEAN
(
    cd "$LEAN_PKG"
    lake env lean "$work/nested/Nested.lean"
    lake env lean "$work/needed/Needed.lean"
)
printf 'PASS: unused opaque traits excluded; genuinely referenced opaque trait retained\n'
