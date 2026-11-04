//! A genuinely referenced external trait must retain its fallback declaration.

pub fn preserve<R: dep::Needed>(reader: R) -> R {
    reader
}
