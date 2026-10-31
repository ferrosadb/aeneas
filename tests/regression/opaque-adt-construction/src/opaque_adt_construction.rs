//! Constructing a type that the extraction does not model must not end the run.
//!
//! Charon can be told to leave a type opaque (here through `charon-args`). Its declaration is then
//! present but has no fields, and asking for them raised `Invalid_argument` from deep inside the
//! evaluator, with the whole declaration in the message. The item cannot be modelled, so the correct
//! behaviour is to report it and skip the function, leaving the rest of the crate alone.

pub struct Point {
    pub x: u8,
    pub y: u8,
}

pub fn mirror(p: &Point) -> Point {
    Point { x: p.y, y: p.x }
}

pub fn origin() -> Point {
    Point { x: 0, y: 0 }
}
