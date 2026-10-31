//! A trait whose method is generic over a trait declared later in the file.
//!
//! The bound becomes a trait-clause field, so the declaration mentions `Reader` before it exists
//! if traits are emitted in name order. Lean has no forward references.

pub trait Decode: Sized {
    fn decode<R: Reader>(r: &R) -> Self;
}

pub trait Reader {
    fn read(&self) -> u32;
}

pub struct D;

impl Decode for D {
    fn decode<R: Reader>(r: &R) -> Self {
        let _ = r.read();
        D
    }
}

impl Reader for D {
    fn read(&self) -> u32 {
        0
    }
}
