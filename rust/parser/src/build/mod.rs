//! Every DERIVATION `attribute_collector.rb` (and its siblings) performs —
//! not raw parsing, but turning already-gated words/arguments into IR
//! facts a bluebook never spells directly: which path an `identified_by`
//! form derives, which attribute a `reference_to` mints, how an inline
//! `one_of(...)` becomes a synthesized closed-set value object, how a
//! query's block-parameter sugar becomes `wheres`, how a read model's
//! `include` list pluralizes and dedupes.
//!
//! ALL STUBBED FOR STAGE 1 — parse/*.rs never reaches these yet (every
//! construct handler stops at `not_yet_implemented` before attempting to
//! build anything). Each submodule names its own Ruby source and gets its
//! own unit test once Stage 2 actually calls it, per the plan's own
//! "every derivation gets its own named module and unit test" framing.

pub mod closed_sets;
pub mod identity;
pub mod naming;
pub mod pattern_subset;
pub mod query_derive;
pub mod query_options;
pub mod read_model;
pub mod references;
