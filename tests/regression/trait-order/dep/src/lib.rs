//! External traits that mention each other, declared in an order Lean cannot emit verbatim.

pub trait Decode: Sized {
    fn decode<R: Reader>(r: &R) -> Self;
}

pub trait Reader {
    fn read(&self) -> u32;
}
