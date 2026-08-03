pub mod expression;
// THE HAND-WRITTEN `.bluebook` TEXT READER, gated as one cluster — see
// `parser`'s own feature doc in rust/Cargo.toml. `parser_helpers` stays
// UNGATED below: `translation::parser` (a separate, smaller, always-on
// parser) shares its string/symbol extraction primitives, so it cannot
// go behind the same flag without breaking a module this cut was never
// about.
#[cfg(feature = "parser")]
pub mod generic_bind;
pub mod hecksagon_helpers;
pub mod hecksagon_ir;
pub mod hecksagon_parser;
pub mod ir;
#[cfg(feature = "parser")]
pub mod ir_dispatch_words;
pub mod ir_structs;
pub mod ir_syntax;
#[cfg(feature = "parser")]
pub mod ir_syntax_bindings;
#[cfg(feature = "parser")]
pub mod ir_syntax_flags;
#[cfg(feature = "parser")]
pub mod ir_syntax_text;
pub mod ir_vocabulary;
#[cfg(feature = "parser")]
pub mod parse_blocks;
#[cfg(feature = "parser")]
pub mod parser;
pub mod projected;
pub mod parser_helpers;
pub mod pattern_subset;
pub mod project_loader;
pub mod router;
pub mod translation;
pub mod world;
