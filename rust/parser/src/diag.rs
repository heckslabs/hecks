//! Diagnostics — the one shape every refusal in this crate takes.
//!
//! **No lenient mode, ever.** An unrecognized construct is always a hard
//! error, never silently skipped — that's the single most important design
//! invariant in the whole Rust-parser plan (see the plan's framing of why
//! `~/Projects/hecks/rust`'s own abandoned parser was dangerous: it "failed
//! open", returning VALID for a real bluebook file while silently dropping
//! identity). A `Diagnostic` is how every gate (shape/word/argument/body)
//! reports that hard failure — always naming the file, the line, what was
//! found, and what would have been legal instead.

use std::fmt;

#[derive(Debug, Clone)]
pub struct Diagnostic {
    pub file: String,
    pub line: usize,
    pub message: String,
    /// The legal alternatives at this point — a word gate names every other
    /// word admitted in the current context, an argument gate names the
    /// expected shape. Empty when there's nothing more specific to offer
    /// (a shape error, say).
    pub expected: Vec<String>,
}

impl Diagnostic {
    pub fn new(file: impl Into<String>, line: usize, message: impl Into<String>) -> Self {
        Self {
            file: file.into(),
            line,
            message: message.into(),
            expected: Vec::new(),
        }
    }

    pub fn with_expected(mut self, expected: Vec<String>) -> Self {
        self.expected = expected;
        self
    }

    /// The one place "not yet implemented" is spelled — every construct
    /// handler that hasn't been built yet returns this rather than a
    /// generic panic, so an unbuilt path fails through a real, named
    /// diagnostic rather than an unstructured crash. Most real chapters
    /// parse for real now (spec/parser_parity_spec.rb's REAL_PARITY_MEMBERS
    /// — see ir.rs's own header); this is what a genuinely-still-pending
    /// member (that spec's PENDING_MEMBERS table) or an unsupported
    /// construct inside an otherwise-real chapter hits. Distinguishing "the
    /// grammar doesn't admit this" (a real parse error) from "the grammar
    /// admits this and this parser doesn't implement it yet" still matters
    /// for how the differential harness reports failures.
    pub fn not_yet_implemented(
        file: impl Into<String>,
        line: usize,
        what: impl fmt::Display,
    ) -> Self {
        Self::new(
            file,
            line,
            format!("not yet implemented: {what} (Stage 1 — see spec/parser_coverage_spec.rb)"),
        )
    }
}

impl fmt::Display for Diagnostic {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}:{}: {}", self.file, self.line, self.message)?;
        if !self.expected.is_empty() {
            write!(f, " (expected one of: {})", self.expected.join(", "))?;
        }
        Ok(())
    }
}

pub type ParseResult<T> = Result<T, Diagnostic>;
