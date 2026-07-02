// rust/tests/validator_keywords_test.rs
//
// Locks the unknown-block-keyword validator (DX perfection game, Tier-0 #3) :
// a `<word> "." do` block-opener inside an aggregate whose word is a near-miss
// of a real keyword (`commnd` -> `command`) must surface a graceful INVALID
// with a `did you mean` hint, instead of the parser silently walking past the
// whole block (dropping the command from the IR) and validate complaining about
// an unrelated symptom ("Widget has no commands") — the scout's #1 gripe.
//
// [antibody-exempt: rust/tests/validator_keywords_test.rs — kernel-surface test
//  for the parser + validator. It asserts on Rust IR + validator output, so it
//  is necessarily Rust. Mirrors validator_rules_test.rs / block_grammar_test.rs.]

use storehouse::parser;
use storehouse::validator_keywords::unknown_keyword_errors;

#[test]
fn commnd_typo_surfaces_did_you_mean_command() {
    let domain = parser::parse(r#"Hecks.bluebook "T" do
      aggregate "Widget" do
        description "A widget"
        commnd "MakeWidget" do
          role "Maker"
        end
      end
    end"#);
    let errors = unknown_keyword_errors(&domain);
    assert!(
        errors.iter().any(|e|
            e.contains("commnd") && e.contains("did you mean") && e.contains("command")),
        "a `commnd` typo must surface a did-you-mean hint pointing at `command`, got: {:?}",
        errors
    );
}

#[test]
fn well_formed_aggregate_records_no_unknown_keywords() {
    let domain = parser::parse(r#"Hecks.bluebook "T" do
      aggregate "Widget" do
        description "A widget"
        command "MakeWidget" do
          role "Maker"
        end
        query "All" do
        end
      end
    end"#);
    assert!(
        unknown_keyword_errors(&domain).is_empty(),
        "a bluebook whose every block opener is a real keyword must record no unknown keywords"
    );
}

#[test]
fn far_word_is_left_alone_not_guessed() {
    // A genuinely-unhandled far construct (not within edit-distance 2 of any
    // block keyword) must NOT be guessed at — it is silently walked past exactly
    // as before, so real unknown constructs raise no false did-you-mean noise.
    let domain = parser::parse(r#"Hecks.bluebook "T" do
      aggregate "Widget" do
        description "A widget"
        command "MakeWidget" do
          role "Maker"
        end
        specification "SomeSpec" do
        end
      end
    end"#);
    assert!(
        unknown_keyword_errors(&domain).is_empty(),
        "a far unknown construct (`specification`) must not be guessed at as a typo"
    );
}
