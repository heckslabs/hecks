//! Rust-native specializer for `hecks_life/src/validator_corpus.rs`.
//!
//! Emits the three corpus-aware lint extensions
//! (`corpus_phantom_trigger_errors`, `identified_by_warnings`,
//! `policy_event_warnings`) byte-identical to the tracked file. Reads
//! the `CorpusRule` fixture rows from validator_corpus_shape, sorts by
//! `order`, and concatenates each row's verbatim `.rs.frag` snippet
//! (doc comment + signature + body + closing brace) separated by a
//! single blank line.
//!
//! All three rules are sui generis — every body is a unique walk of
//! `domain.aggregates` / `domain.policies` that doesn't fit a
//! check_kind primitive. The specializer is correspondingly small : no
//! body emission, just header + imports + N verbatim snippets.
//!
//! Usage:
//!   let rust = validator_corpus::emit(repo_root)?;
//!   print!("{}", rust);
//!
//! [antibody-exempt: hecks_life/src/specializer/validator_corpus.rs —
//!  i146 piece 2 — Rust-native specializer implementation]

use crate::specializer::util;
use std::error::Error;
use std::path::Path;

const SHAPE_REL: &str =
    "codegen/validator_corpus_shape/fixtures/validator_corpus_shape.fixtures";

pub fn emit(repo_root: &Path) -> Result<String, Box<dyn Error>> {
    let shape = repo_root.join(SHAPE_REL);
    let fixtures = util::load_fixtures(&shape)?;
    let rules = util::by_aggregate_sorted(&fixtures, "CorpusRule", "order");

    let mut out = String::new();
    out.push_str(HEADER);
    out.push_str(IMPORTS);
    for (i, rule) in rules.iter().enumerate() {
        if i > 0 {
            out.push('\n');
        }
        let snippet_path = repo_root.join(util::attr(rule, "snippet_path"));
        let body = util::read_snippet_raw(&snippet_path)?;
        out.push_str(&body);
    }
    Ok(out)
}

const HEADER: &str = r#"//! Validator extensions that run against the corpus-merged Domain
//! (every bluebook in the corpus joined into one IR via
//! `load_combined_domain`). Live here rather than in `validator.rs`
//! or `validator_warnings.rs` because those two files are
//! specializer targets — byte-identical with what
//! `hecks-life specialize <name>` emits — and adding hand-written
//! functions to them breaks the 2nd Futamura proof.
//!
//! GENERATED FILE — do not edit.
//! Source:    codegen/validator_corpus_shape/
//! Regenerate: hecks-life specialize validator_corpus --output hecks_life/src/validator_corpus.rs
//! Contract:  hecks_life/src/specializer/validator_corpus.rs (Rust-native)
//!
//! Four rules :
//!
//!   - `corpus_phantom_trigger_errors` — INVALID-grade : a policy's
//!     `trigger_command` is not declared by any aggregate in the
//!     corpus. The runtime would explode at dispatch time.
//!
//!   - `identified_by_warnings` — advisory : an aggregate has a
//!     lifecycle or self-referencing command but no identified_by,
//!     so dispatch counter-mints a fresh id on every fire and the
//!     lifecycle state never advances past pending.
//!
//!   - `policy_event_warnings` — advisory : a policy subscribes to
//!     an event that no command emits anywhere in the corpus. The
//!     policy is dangling — placeholder, or a typo.
//!
//!   - `bare_name_collisions` — advisory : a command name is declared
//!     on more than one aggregate across the corpus. Bare-name
//!     dispatch is ambiguous — qualify call sites with
//!     `Aggregate.Command` to disambiguate. i156.

"#;

const IMPORTS: &str = "use std::collections::HashSet;\n\nuse crate::ir::Domain;\n\n";
