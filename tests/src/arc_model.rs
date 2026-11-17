//@ [!lean] skip

//! Regression test for the `Arc` model.
//!
//! `Arc<T>` had no model, so every crate that named it got an opaque `sorry` for the
//! type and one for each method it called (`new`, `deref`, `try_unwrap`, `clone`). The
//! model erases `Arc<T>` to `T`, as `Box<T>` is erased: extracted code is pure, so a
//! shared immutable value and an owned one carry the same information.
//!
//! `try_unwrap` is the one call whose outcome depends on the reference count, which a
//! value does not carry. The model leaves that choice opaque, so `owned_or_shared` below
//! has to be correct on both branches, and it is: both decode the same row.

use std::sync::Arc;

pub struct Row {
    pub key: u32,
    pub cells: Vec<u32>,
}

/// `Arc::new`, then a read through `Deref`.
pub fn share_and_read(key: u32) -> u32 {
    let row = Arc::new(Row { key, cells: Vec::new() });
    row.key
}

/// `Clone` on an `Arc` shares the value; it does not need `Row: Clone`.
pub fn share_twice(row: Arc<Row>) -> (Arc<Row>, Arc<Row>) {
    let other = Arc::clone(&row);
    (row, other)
}

/// Take the row by move when this is the only reference, borrow it otherwise.
pub fn owned_or_shared(row: Arc<Row>) -> u32 {
    match Arc::try_unwrap(row) {
        Ok(owned) => owned.key,
        Err(shared) => shared.key,
    }
}

/// A vector of shared rows, the shape a storage partition holds.
pub fn first_key(rows: &Vec<Arc<Row>>) -> Option<u32> {
    rows.first().map(|r| r.key)
}
