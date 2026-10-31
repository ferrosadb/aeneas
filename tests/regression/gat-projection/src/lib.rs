//! A signature that projects a generic associated type.
//!
//! `Self::Item<'a>` makes the projection carry generic arguments, which
//! SymbolicToPureTypes.translate_fwd_ty treats as unimplemented and asserts on. The assert
//! raises CFailure that nothing catches, so the whole run dies with a stack trace.
//! The behaviour under test: such an item is reported and skipped, never fatal.

pub trait Lending {
    type Item<'a>
    where
        Self: 'a;

    fn get<'a>(&'a self) -> Self::Item<'a>;
}

pub struct Always;

impl Lending for Always {
    type Item<'a> = &'a u32;

    fn get<'a>(&'a self) -> Self::Item<'a> {
        &0
    }
}
