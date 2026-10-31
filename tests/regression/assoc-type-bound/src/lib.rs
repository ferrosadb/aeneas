//! A trait method whose signature binds an associated type.
//!
//! `K: Store<Key = u32>` puts a trait type constraint on the signature, which the translator
//! does not model. It used to abort the whole run with an uncaught CFailure from
//! SymbolicToPureTypes.translate_fun_sigs; it must be a recorded error instead.

pub trait Store {
    type Key;
    fn key(&self) -> Self::Key;
}

pub trait Loader {
    fn load<K: Store<Key = u32>>(k: K) -> u32;
}

pub fn key_of<K: Store<Key = u32>>(k: K) -> u32 {
    let _ = k.key();
    0
}
