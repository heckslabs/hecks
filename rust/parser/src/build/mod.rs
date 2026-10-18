//! Derivations that turn parsed constructs into IR facts a bluebook never spells directly,
//! one submodule per Ruby source (`attribute_collector.rb` and its siblings).

pub mod closed_sets;
pub mod identity;
pub mod named_pattern;
pub mod naming;
pub mod pattern_subset;
pub mod query_derive;
pub mod query_inference;
pub mod query_options;
pub mod read_model;
pub mod references;
