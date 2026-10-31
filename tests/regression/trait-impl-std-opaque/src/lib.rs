//! An impl whose trait declaration is not in the translation set must not end the run.
//!
//! A `str` search pulls in `core::str::pattern::Pattern` implementations for `char` and `&str`.
//! Charon leaves those declarations out, so naming the impl's trait was a lookup that raised
//! `Not_found` and killed the whole translation. The item cannot be modelled without its trait, so
//! the correct behaviour is to report it and skip it.

pub fn index_of(haystack: &str, needle: char) -> usize {
    match haystack.find(needle) {
        Some(i) => i,
        None => haystack.len(),
    }
}

pub fn contains_word(text: &str, word: &str) -> bool {
    text.contains(word)
}
