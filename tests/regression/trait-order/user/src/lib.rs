//! Uses dep's traits so charon emits their declarations as external.

pub fn read_it<R: dep::Reader>(r: &R) -> u32 {
    r.read()
}
