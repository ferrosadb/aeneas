/- `alloc::sync`: `Arc<T>` is `T` in the extracted code.

Extracted code is pure: a value cannot be observed through two names, so a shared,
immutable `Arc<T>` and an owned `T` hold the same information. `Arc::new`, `deref` and
`clone` are therefore the identity, the way `Box` is.

The one thing the model cannot see is the reference count. `Arc::try_unwrap` hands the
value back as `Ok` only when the count is one, and the count is not part of the value.
`try_unwrap.isUnique` leaves that choice opaque: a proof about a caller must hold for
both outcomes, and since both carry the same value, a caller whose two branches compute
the same result (decode an owned row, or decode a borrowed one) is still provable.
-/
module
public import Aeneas.Std.Alloc.Alloc
public import Aeneas.Std.Core.Ops
public import Aeneas.Std.Core.Core
public import Aeneas.Std.Core.Result
public section

namespace Aeneas.Std

open Result

@[expose, rust_type "alloc::sync::Arc"]
def alloc.sync.Arc (T : Type u) : Type u := T

@[expose, rust_fun "alloc::sync::{alloc::sync::Arc<@T>}::new" -canFail]
def alloc.sync.Arc.new {T : Type u} (x : T) : alloc.sync.Arc T := x

/-- Whether `Arc::try_unwrap` finds its argument uniquely owned. Rust decides it from the
reference count, which this model does not track, so it is opaque: nothing can be proved
from it, and a proof about a caller has to cover both answers. -/
opaque alloc.sync.Arc.try_unwrap.isUnique {T : Type u} : alloc.sync.Arc T → Bool

@[expose, rust_fun "alloc::sync::{alloc::sync::Arc<@T>}::try_unwrap" -canFail
    (keepParams := [true, false])]
def alloc.sync.Arc.try_unwrap {T : Type u} (x : alloc.sync.Arc T) :
    core.result.Result T (alloc.sync.Arc T) :=
  if alloc.sync.Arc.try_unwrap.isUnique x then .Ok x else .Err x

@[expose, rust_fun "alloc::sync::{core::ops::deref::Deref<alloc::sync::Arc<@T>, @T>}::deref"
    -canFail (keepParams := [true, false])]
def alloc.sync.Arc.deref {T : Type u} (x : alloc.sync.Arc T) : T := x

/-- Trait instance -/
@[expose, reducible, rust_trait_impl "core::ops::deref::Deref<alloc::sync::Arc<@T>, @T>"
    (keepParams := [true, false])]
def core.ops.deref.DerefArcInst (T : Type u) :
    core.ops.deref.Deref (alloc.sync.Arc T) T := {
  deref x := ok (alloc.sync.Arc.deref x)
}

/-- Cloning an `Arc` shares the value; it never needs `T : Clone`. -/
@[expose, rust_fun "alloc::sync::{core::clone::Clone<alloc::sync::Arc<@T>>}::clone" -canFail
    (keepParams := [true, false]) (keepTraitClauses := [false])]
def alloc.sync.Arc.clone {T : Type u} (x : alloc.sync.Arc T) : alloc.sync.Arc T := x

/-- Trait instance -/
@[expose, reducible, rust_trait_impl "core::clone::Clone<alloc::sync::Arc<@T>>"
    (keepParams := [true, false]) (keepTraitClauses := [false])]
def core.clone.CloneArc (T : Type u) : core.clone.Clone (alloc.sync.Arc T) := {
  clone x := ok (alloc.sync.Arc.clone x)
}

/-! The two outcomes `try_unwrap` can have, stated so a caller's proof can case on them. -/

theorem alloc.sync.Arc.try_unwrap_cases {T : Type u} (x : alloc.sync.Arc T) :
    alloc.sync.Arc.try_unwrap x = .Ok x ∨ alloc.sync.Arc.try_unwrap x = .Err x := by
  unfold alloc.sync.Arc.try_unwrap
  split <;> simp

theorem alloc.sync.Arc.deref_new {T : Type u} (x : T) :
    alloc.sync.Arc.deref (alloc.sync.Arc.new x) = x := rfl

end Aeneas.Std
