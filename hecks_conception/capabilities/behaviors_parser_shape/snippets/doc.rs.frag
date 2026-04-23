//! Behaviors parser — reads `_behavioral_tests.bluebook` files into a TestSuite.
//!
//! GENERATED FILE — do not edit.
//! Source:    hecks_conception/capabilities/behaviors_parser_shape/
//! Regenerate: hecks-life specialize behaviors_parser --output hecks_life/src/behaviors_parser.rs
//! Contract:  hecks_life/src/specializer/behaviors_parser.rs (Rust-native)
//! Tests:     in-file #[cfg(test)] mod tests
//!
//! Fourth parser retirement after validator.rs, dump.rs, and
//! hecksagon_parser.rs. Reuses the hecksagon parser-shape template
//! (LineParser + LineDispatch + ParserHelper) with two extensions:
//! an `else_if` loop style and a `tests_snippet` attribute carrying
//! the inline `#[cfg(test)]` block verbatim.
//!
//! Surface (kept small on purpose):
//!
//!   Hecks.behaviors "Pizzas" do
//!     vision "..."
//!     test "description" do
//!       tests "CmdName", on: "Aggregate"          # required
//!       tests "QueryName", on: "Aggregate", kind: :query
//!       setup "CmdName", arg: "value", n: 1       # zero or more
//!       input arg: "value"                        # one
//!       expect attr: "value", count: 2            # one
//!     end
//!   end
//!
//! Mirrors `parser.rs` in style: line-based, `ends_with_do_block` for
//! depth tracking, `extract_string`/`extract_after` for token extraction.
