//! Diagnostics: the one shape every refusal takes.
//!
//! There is no lenient mode: an unrecognized construct is always a hard error, never skipped.

use std::fmt;

/// A refusal: where it happened, what is wrong and what would have been accepted.
#[derive(Debug, Clone)]
pub struct Diagnostic {
    pub file: String,
    pub line: usize,
    /// The 1-based character column the problem starts at; `None` for a construct that is
    /// refused as a whole line, which is every refusal of the Ruby-shaped grammar.
    pub column: Option<usize>,
    pub message: String,
    /// The legal alternatives at this point; empty when there is nothing more specific.
    pub expected: Vec<String>,
}

impl Diagnostic {
    /// A refusal of a whole line.
    pub fn new(file: impl Into<String>, line: usize, message: impl Into<String>) -> Self {
        Self {
            file: file.into(),
            line,
            column: None,
            message: message.into(),
            expected: Vec::new(),
        }
    }

    /// The same refusal, pointing at the character column it starts at.
    pub const fn with_column(mut self, column: usize) -> Self {
        self.column = Some(column);
        self
    }

    /// The same refusal, listing what would have been accepted.
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
        match self.column {
            Some(column) => write!(f, "{}:{}:{}: {}", self.file, self.line, column, self.message)?,
            None => write!(f, "{}:{}: {}", self.file, self.line, self.message)?,
        }
        if !self.expected.is_empty() {
            write!(f, " (expected one of: {})", self.expected.join(", "))?;
        }
        Ok(())
    }
}

/// A parse that either succeeds or is refused with a [`Diagnostic`].
pub type ParseResult<T> = Result<T, Diagnostic>;
