//! External trait carried by LLBC even when its declaration is not translated.
pub trait Needed {
    fn value(&self) -> u32;
}
