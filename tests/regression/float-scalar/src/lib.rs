//! A float scalar in a data type, with no float arithmetic.
//!
//! The Lean backend prints the scalar type as F64, a name that exists nowhere in Aeneas/Std, so
//! the declaration fails with "constructor field ... contains universe level metavariables" and
//! every later reference to the type reports unknownIdentifier. Floats are not modelled by Aeneas,
//! so the emitted name has to be one Lean actually has.

pub enum Value {
    Bool(bool),
    Unsigned(u64),
    Float(f64),
    Small(f32),
}

pub fn wrap(x: f64) -> Value {
    Value::Float(x)
}

pub fn wrap_small(x: f32) -> Value {
    Value::Small(x)
}
