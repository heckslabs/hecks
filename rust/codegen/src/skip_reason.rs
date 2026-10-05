//! A skip decision plus the construct family that forced it (the retired Ruby generator's `skip_reason.rb`).
//! `construct` goes to `manifest.json` beside the reason so tools read the family, not the prose.

use std::fmt;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SkipReason {
    pub construct: String,
    pub text: String,
}

pub fn skip(construct: impl Into<String>, text: impl Into<String>) -> SkipReason {
    SkipReason { construct: construct.into(), text: text.into() }
}

/// Keeps `inner`'s construct with new wording.
pub fn reskip(inner: &SkipReason, text: impl Into<String>) -> SkipReason {
    SkipReason { construct: inner.construct.clone(), text: text.into() }
}

impl fmt::Display for SkipReason {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.text)
    }
}
