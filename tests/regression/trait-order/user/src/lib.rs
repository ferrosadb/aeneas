//! Uses only `Decode`; `Reader` is reachable only through it, so its declaration is a *transitive*
//! external item rather than something this crate names directly -- the position of a downstream
//! crate with respect to std's `Expected`/`Error`/`Deserializer`.

pub fn decode_it<R: dep::Reader, D: dep::Decode>(r: &R) -> D {
    D::decode(r)
}
