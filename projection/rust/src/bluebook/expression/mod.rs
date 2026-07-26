//! expression - the sublanguage a predicate is allowed to be.
//!
//! Mirrors lib/hecksagain/bluebook/expression/ file for file:
//!
//!   ruby resolver.rb   <->  rust resolver.rs    the leaves
//!   ruby evaluator.rb  <->  rust evaluator.rs   the verdict
//!
//! Ruby also has extractor.rb, which has no Rust twin on purpose: extraction
//! reads Ruby source with Prism, and only the Ruby side can do that. Rust gets
//! the canonical text already extracted — the whole reason the sublanguage is
//! carried as text.
//!
//! The two sides are specified once, in lib/hecksagain/grammar/expression.bluebook,
//! and implemented twice. bin/parity is what proves the pair agree.

pub mod evaluator;
pub mod resolver;

#[cfg(test)]
mod tests;
