# Wide-enum (tag model) contract — fixed, do not redesign unilaterally

Both sides of this change implement one agreed encoding. If something here cannot
work, say so in your final report and stop at the smallest coherent state — do not
invent a second encoding, and do not edit files outside your owned set.

## Why

Lean 4.35 rejects an inductive with more than **244 constructors**
(`tag for constructor 'X.c244' is too big`). `rustls::enums::CipherSuite` has 376/377
variants, which today kills the whole enum and cascades into ~94 errors in
`ferrosa_net`. Measured: hand-replacing the enum with the encoding below on the
real emitted file took that module from 101 to 40 elaboration errors with the
cascade gone.

## The encoding (exact Lean text)

For `type <name>` (generics `<params>`) with variants `v0 .. vn-1`, when
`n > 244` and backend is Lean:

```lean
structure <name> (<params>) where
  disc : Std.U16
  f<i> : Option (<ty0> × <ty1>) := none     -- one field per variant index i that has fields
```

Constructor `def`s, emitted after the type declaration group:

```lean
def <name>.<Ctor> (a0 : <ty0>) (a1 : <ty1>) : <name> :=
  { disc := UScalar.ofNatCore <i> (by decide), f<i> := some (a0, a1) }

def <name>.<Ctor> : <name> := { disc := UScalar.ofNatCore <i> (by decide) }
```

Single-field payload uses `some a0`, not `some (a0)`. Zero-payload variants get no
`f` field.

Hard constraints established by hand-editing the emitted file:

1. Numerals do not work: there is no `OfNat U16`. Always
   `UScalar.ofNatCore <literal> (by decide)`.
2. The `@[discriminant isize, rust_type "..."]` attribute must stay **adjacent** to
   the declaration it precedes. Inserting a doc comment between them is a parse
   error.
3. `structure … where` uses the same `where` the printer already emits for Lean
   enums; only the qualifier (`inductive` → `structure`) and the body change.

## Match form (side B)

For a scrutinee whose type is a wide enum, `match` becomes a chain of tag tests:

```lean
(if x.disc = UScalar.ofNatCore <i> (by decide)
 then <branch i body>
 else if x.disc = ... then ... else <default>)
```

Payload projection inside a branch: `let a0 := Option.get x.f<i>` (a branch is only
reachable when the tag matches, so the `Option` is inhabited). Bind `x` once with
`let` if the scrutinee is not already a variable. Equality on `Std.U16` is `=`
(decidable, `Std.U16` has `DecidableEq` in the Aeneas library).

## Ownership

| Side | Owns | Must not touch |
|---|---|---|
| A (`~/src/aeneas-wt-types`, branch `wide-enum-types`) | the shared predicate, the Lean qualifier for wide enums, the enum body, the constructor `def`s | `Extract.ml` match arm, `ExtractBase.ml` discriminant path |
| B (`~/src/aeneas-wt-match`, branch `wide-enum-match`) | `extract_texpr`'s `| Match branches ->` arm, `Discriminant`/`read_discriminant` | `ExtractTypes.ml`, the predicate's file |

Shared predicate, written by **A**, consumed by **B**:

```ocaml
(* src/extract/WideEnum.ml *)
val threshold : int                                    (* 244 *)
val is_wide_enum : extraction_ctx -> TypeDeclId.id -> bool
```

If B needs it before A has landed it, B defines a local `threshold` constant and a
local predicate with the same semantics in its own file, and says so in its report;
the integrator deduplicates. Never edit the other side's file.

## Build and test

```bash
export OPAMROOT=$HOME/.opam-aeneas
cd <worktree>/src && eval $(opam env --switch=aeneas --set-switch) && dune build
```

Translation + elaboration (both are minutes, run them in the background and poll):

```bash
cd ~/src/ferrosa-suite/ferrosa
~/src/aeneas-wt-<side>/src/_build/default/main.exe -backend lean -dest /tmp/we-<side> ferrosa_net.llbc
cd ~/.local/aeneas/backends/lean && lake env lean /tmp/we-<side>/FerrosaNet.lean 2>&1 | grep -c error
```

Baseline for comparison, on this machine, same `llbc`: **101** errors, 94 of them
the `CipherSuite` cascade. After the (still partial) encoding: **~40**. Side B
alone will not move the count (the enum is still an inductive until A lands).
