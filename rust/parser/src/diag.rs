//! Diagnostics: the one shape every refusal takes.
//!
//! There is no lenient mode: an unrecognized construct is always a hard error, never skipped.

use std::fmt;

#[derive(Debug, Clone)]
pub struct Diagnostic {
    pub file: String,
    pub line: usize,
    pub message: String,
    /// The legal alternatives at this point; empty when there is nothing more specific.
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

    /// Diagnostic for a construct the grammar admits but this parser does not implement yet.
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
