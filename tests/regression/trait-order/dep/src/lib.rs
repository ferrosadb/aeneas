//! Two traits that mention each other, so charon groups their declarations as mutually recursive.
//!
//! Aeneas prints a recursive group in id order, which leaves one declaration referring forward to
//! the other. Lean has no forward references; a `mutual` block is what it needs.

pub trait Decode: Sized {
    fn decode<R: Reader>(r: &R) -> Self;
}

pub trait Reader {
    fn decode_with<D: Decode>(&self) -> D;
}
