/- `core::task` and the slice of the `futures` crates a lazy stream goes through.

A crate that builds a stream with `StreamExt::map` used to get the `Map` adapter as an opaque
`sorry` type and its `Stream` implementation as an opaque `{ sorry }` instance, which Lean
cannot even elaborate (it reads `{ sorry }` as a one-element set). Modelling the pieces here
lets that code extract:

* `Poll` is the enum it is; `Context` carries the waker, and the model has no scheduler, so it
  carries nothing. Polling threads the context through unchanged.
* `Stream` is declared with the one method crates call, `poll_next`, in the shape Aeneas
  generates for it (the pinned receiver and the context are threaded back out).
* `FnOnce1`/`FnMut1` are `futures`' one-argument function traits; their blanket
  implementations forward to `FnOnce`/`FnMut`, as in `futures_util::fns`.
* `Map` holds the inner stream and the function, and polls exactly as `futures_util` does:
  poll the inner stream, and map an item when one is ready.

`StreamExt` is not modelled: each crate's extraction declares the methods it uses, and its
`map` returns this `Map`.
-/
module
public import Aeneas.Std.Core.Core
public import Aeneas.Std.Core.Ops
public import Aeneas.Std.Core.Pin
public section

namespace Aeneas.Std

open Result

@[rust_type "core::task::poll::Poll"]
inductive core.task.poll.Poll (T : Type) where
| Ready : T → core.task.poll.Poll T
| Pending : core.task.poll.Poll T

/-- A task's context. In Rust it carries the waker that reschedules a pending task; the model
has no scheduler, so it carries nothing and every poll hands it back unchanged. -/
@[expose, rust_type "core::task::wake::Context" (mutRegions := #[0])]
def core.task.wake.Context : Type := Unit

@[rust_trait "futures_core::stream::Stream"]
structure futures_core.stream.Stream (Self : Type) (Self_Item : Type) where
  poll_next : core.pin.Pin Self → core.task.wake.Context → Result
    ((core.task.poll.Poll (Option Self_Item)) × (core.pin.Pin Self) ×
    core.task.wake.Context × (core.task.wake.Context → core.task.wake.Context))

@[rust_trait "futures_util::fns::FnOnce1"]
structure futures_util.fns.FnOnce1 (Self : Type) (A : Type) (Self_Output : Type) where
  call_once : Self → A → Result Self_Output

@[rust_trait "futures_util::fns::FnMut1" (parentClauses := ["FnOnce1Inst"])]
structure futures_util.fns.FnMut1 (Self : Type) (A : Type) (Self_Clause0_Output : Type)
  where
  FnOnce1Inst : futures_util.fns.FnOnce1 Self A Self_Clause0_Output
  call_mut : Self → A → Result (Self_Clause0_Output × Self)

/-- Trait instance: every `FnOnce(A) -> R` is a `FnOnce1<A>`. -/
@[expose, reducible, rust_trait_impl "futures_util::fns::FnOnce1<@T, @A, @R>"]
def futures_util.fns.FnOnce1.Blanket {T : Type} {A : Type} {R : Type}
    (FnOnceInst : core.ops.function.FnOnce T A R) : futures_util.fns.FnOnce1 T A R := {
  call_once := FnOnceInst.call_once
}

/-- Trait instance: every `FnMut(A) -> R` is a `FnMut1<A>`. -/
@[expose, reducible, rust_trait_impl "futures_util::fns::FnMut1<@T, @A, @R>"]
def futures_util.fns.FnMut1.Blanket {T : Type} {A : Type} {R : Type}
    (FnMutInst : core.ops.function.FnMut T A R) : futures_util.fns.FnMut1 T A R := {
  FnOnce1Inst := futures_util.fns.FnOnce1.Blanket FnMutInst.FnOnceInst
  call_mut := FnMutInst.call_mut
}

/-- `StreamExt::map`'s adapter: the inner stream and the function applied to its items. -/
@[rust_type "futures_util::stream::stream::map::Map"]
structure futures_util.stream.stream.map.Map (St : Type) (F : Type) where
  stream : St
  f : F

/-- Poll the inner stream; when it yields an item, map it. A pending or finished inner
stream is passed through, as in `futures_util::stream::Map::poll_next`. -/
@[expose]
def futures_util.stream.stream.map.Map.poll_next {St : Type} {F : Type} {Item : Type}
    {Out : Type} (StreamInst : futures_core.stream.Stream St Item)
    (FnMut1Inst : futures_util.fns.FnMut1 F Item Out)
    (self : core.pin.Pin (futures_util.stream.stream.map.Map St F))
    (cx : core.task.wake.Context) :
    Result ((core.task.poll.Poll (Option Out)) ×
      (core.pin.Pin (futures_util.stream.stream.map.Map St F)) ×
      core.task.wake.Context × (core.task.wake.Context → core.task.wake.Context)) := do
  let (polled, stream, cx1, back) ← StreamInst.poll_next self.stream cx
  match polled with
  | .Pending => ok (.Pending, { self with stream := stream }, cx1, back)
  | .Ready none => ok (.Ready none, { self with stream := stream }, cx1, back)
  | .Ready (some item) =>
    let (out, f) ← FnMut1Inst.call_mut self.f item
    ok (.Ready (some out), { stream := stream, f := f }, cx1, back)

/-- Trait instance -/
@[expose, reducible, rust_trait_impl
  "futures_core::stream::Stream<futures_util::stream::stream::map::Map<@St, @F>, @Clause1_Clause0_Output>"]
def futures_util.stream.stream.map.Map.Insts.Futures_coreStreamStream {St : Type}
    {F : Type} {Item : Type} {Out : Type}
    (StreamInst : futures_core.stream.Stream St Item)
    (FnMut1Inst : futures_util.fns.FnMut1 F Item Out) :
    futures_core.stream.Stream (futures_util.stream.stream.map.Map St F) Out := {
  poll_next := futures_util.stream.stream.map.Map.poll_next StreamInst FnMut1Inst
}

end Aeneas.Std
