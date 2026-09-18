//! Port of `rust/project/skip_reason.rb` — a skip decision carrying the
//! construct family that forced it.
//!
//! Every `*_skip_reason` in this crate answers `None` (generate it) or one
//! of these. `text` is the reason string, unchanged; `construct` is the
//! short, machine-readable family name (`reference_hop_where`,
//! `optional_source`, ...) the SAME branch set when it decided, written to
//! `manifest.json` beside the reason so `bin/rust_coverage` and the
//! differential fuzzer read the family, never the prose.

use std::fmt;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SkipReason {
    pub construct: String,
    pub text: String,
}

/// `skip(construct, text)`. Most constructs are literals; a few are read
/// off the IR (`extras.first`, a read model's own option key).
pub fn skip(construct: impl Into<String>, text: impl Into<String>) -> SkipReason {
    SkipReason { construct: construct.into(), text: text.into() }
}

/// `reskip(inner, text)` — `inner`'s own construct, re-worded.
pub fn reskip(inner: &SkipReason, text: impl Into<String>) -> SkipReason {
    SkipReason { construct: inner.construct.clone(), text: text.into() }
}

impl fmt::Display for SkipReason {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.text)
    }
}
