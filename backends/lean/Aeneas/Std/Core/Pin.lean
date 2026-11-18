module
public meta import Aeneas.Extract.Extract
public section

namespace Aeneas.Std

/-- `Pin<P>` is `P` in the extracted code, the way `Box<T>` is `T`: pinning promises the value
will not move, and a pure model has no addresses for it to move between. -/
@[expose, rust_type "core::pin::Pin"]
def core.pin.Pin (Ptr : Type u) : Type u := Ptr

-- TODO
@[rust_type "core::pin::helper::PinHelper"]
axiom core.pin.helper.PinHelper (Ptr : Type _) : Type

end Aeneas.Std
