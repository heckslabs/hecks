//! Shared diagnostic types for validator-style modules.
//!
//! `Severity`, `Finding`, and the `Finding` constructors are duplicated
//! across duplicate_policy_validator, lifecycle_validator, and
//! io_validator. This module extracts the shared shape so each
//! validator only carries its own rule logic + its own `Report` (which
//! still varies — flat Vec vs static/runtime partition).
//!
//! Extracted 2026-04-23 per inbox i59, blocking Phase B retirement of
//! the diagnostic-style validators. Once each validator imports from
//! here, the per-validator shape only needs to model the rule, not the
//! struct/enum ceremony — unblocking byte-identity Futamura retirement
//! at an acceptable declarativity ratio.
//!
//! Usage (illustrative; not doctest — `crate::` path doesn't resolve
//! in external doctest harness):
//!
//! ```text
//! use crate::diagnostic::{Finding, Severity};
//!
//! let f = Finding::err("<location>", "<message>");
//! let g = Finding::warn("<location>", "<message>");
//! println!("{} {}", f.icon(), f.message);   // ✗ <message>
//! println!("{} {}", g.icon(), g.message);   // ⚠ <message>
//! ```
//!
//! Severity has both variants even when a particular validator only
//! emits one of them (duplicate_policy_validator is Error-only today).
//! Warning is there so lifecycle + io don't need to define their own.

#[derive(Debug, PartialEq)]
pub enum Severity {
    Error,
    Warning,
}

pub struct Finding {
    pub severity: Severity,
    pub location: String,
    pub message: String,
}

impl Finding {
    pub fn err(location: impl Into<String>, message: impl Into<String>) -> Self {
        Finding {
            severity: Severity::Error,
            location: location.into(),
            message: message.into(),
        }
    }

    pub fn warn(location: impl Into<String>, message: impl Into<String>) -> Self {
        Finding {
            severity: Severity::Warning,
            location: location.into(),
            message: message.into(),
        }
    }

    pub fn icon(&self) -> &'static str {
        match self.severity {
            Severity::Error => "✗",
            Severity::Warning => "⚠",
        }
    }
}
