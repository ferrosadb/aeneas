//! A trait method taking a trait object, which Aeneas models as a Dyn-wrapped trait ref.
//!
//! The generated trait structure gets a field whose type mentions
//! [Dyn (fun _dyn => Expected _dyn)]; Lean cannot infer its universes, reporting "Failed to infer
//! universe levels in type of field", and every later reference to the structure then reports
//! unknownIdentifier -- two root causes wearing a hundred errors.

pub trait Expected {
    fn fmt(&self) -> bool;
}

pub trait MyErr: Sized {
    fn custom<T: core::fmt::Display>(msg: T) -> Self;
    fn invalid_value(unexp: u64, exp: &dyn Expected) -> Self;
    fn invalid_length(len: usize, exp: &dyn Expected) -> Self;
}

pub struct E;

impl MyErr for E {
    fn custom<T: core::fmt::Display>(_msg: T) -> Self {
        E
    }
    fn invalid_value(_unexp: u64, _exp: &dyn Expected) -> Self {
        E
    }
    fn invalid_length(_len: usize, _exp: &dyn Expected) -> Self {
        E
    }
}
