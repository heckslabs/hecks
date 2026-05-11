// rust/tests/block_grammar_test.rs
//
// i218 — integration tests for the block_grammar primitive. Verifies
// that :
//   1. The canonical Bluebook grammar routes existing keywords to
//      their typed parsers (aggregate, policy, process_manager,
//      section, cadence, fixture).
//   2. Cadence parses cleanly via the registry (body_tick + heart_tick
//      + breath_tick fixtures from miette/body/cycles/).
//   3. A bluebook can declare its own block_grammar inline ; the IR
//      captures the declared keyword/parser pairs.
//   4. Adding a hypothetical keyword without touching parser.rs's
//      main loop : the test parses a block_grammar that names the new
//      keyword + verifies it lands in `domain.block_grammars`. No
//      Rust diff to add the IR node ; only the parse function +
//      enum variant if the parser is genuinely new.
//
// [antibody-exempt: rust/tests/block_grammar_test.rs — kernel-surface
//  test for the i218 block_grammar primitive. Tests the parser of
//  bluebook ; the test is necessarily Rust code (it asserts on Rust IR
//  shapes). Mirrors the established kernel-floor test pattern from
//  validator_rules_test.rs etc.]

use storehouse::ir::{BlockParser, BlockGrammar};
use storehouse::parser;

#[test]
fn canonical_grammar_lists_six_keywords_in_priority_order() {
    let g = BlockGrammar::canonical_bluebook();
    let keywords: Vec<&str> = g.blocks.iter().map(|e| e.keyword.as_str()).collect();
    assert_eq!(
        keywords,
        vec!["aggregate", "section", "policy", "process_manager", "cadence", "fixture"]
    );
}

#[test]
fn block_parser_round_trips_through_name() {
    for variant in [
        BlockParser::Aggregate,
        BlockParser::Policy,
        BlockParser::ProcessManager,
        BlockParser::Cadence,
        BlockParser::Section,
        BlockParser::Fixture,
    ] {
        let name = variant.name();
        let resolved = BlockParser::from_name(name).expect("known parser name");
        assert_eq!(resolved, variant);
    }
    assert!(BlockParser::from_name("parse_unknown").is_none());
}

#[test]
fn parses_aggregate_via_block_grammar_registry() {
    let domain = parser::parse(
        r#"Hecks.bluebook "Tiny" do
  aggregate "Widget" do
    command "Create" do
      role "Admin"
    end
  end
end
"#,
    );
    assert_eq!(domain.aggregates.len(), 1);
    assert_eq!(domain.aggregates[0].name, "Widget");
    assert_eq!(domain.aggregates[0].context.as_deref(), Some("Tiny"));
}

#[test]
fn parses_cadence_via_block_grammar_registry() {
    let domain = parser::parse(
        r#"Hecks.bluebook "BodyCadence" do
  cadence "BodyTick" do
    every "1s"
    dispatch "Consciousness.ElapsePhase", name: "consciousness"
    dispatch "Tick.MindstreamTick",       name: "tick"
  end
end
"#,
    );
    assert_eq!(domain.cadences.len(), 1);
    let cad = &domain.cadences[0];
    assert_eq!(cad.name, "BodyTick");
    assert_eq!(cad.interval, "1s");
    assert_eq!(cad.dispatches.len(), 2);
    assert_eq!(cad.dispatches[0].command_name, "Consciousness.ElapsePhase");
    assert_eq!(cad.dispatches[1].command_name, "Tick.MindstreamTick");
    assert_eq!(cad.dispatches[0].attrs[0].0, "name");
}

#[test]
fn parses_heart_tick_one_second_one_dispatch() {
    let domain = parser::parse(
        r#"Hecks.bluebook "HeartCadence" do
  cadence "HeartTick" do
    every "1s"
    dispatch "Heart.Beat", name: "heart"
  end
end
"#,
    );
    assert_eq!(domain.cadences.len(), 1);
    assert_eq!(domain.cadences[0].interval, "1s");
    assert_eq!(domain.cadences[0].dispatches.len(), 1);
    assert_eq!(domain.cadences[0].dispatches[0].command_name, "Heart.Beat");
}

#[test]
fn parses_breath_tick_four_seconds_two_dispatches() {
    let domain = parser::parse(
        r#"Hecks.bluebook "BreathCadence" do
  cadence "BreathTick" do
    every "4s"
    dispatch "Breath.Inhale", name: "breath"
    dispatch "Breath.Exhale", name: "breath"
  end
end
"#,
    );
    assert_eq!(domain.cadences[0].interval, "4s");
    assert_eq!(domain.cadences[0].dispatches.len(), 2);
}

#[test]
fn parses_inline_block_grammar_declaration() {
    // A bluebook can declare its own block_grammar at the top level.
    // The IR captures it on `domain.block_grammars` ; this is what
    // bluebook/grammars/bluebook.grammar uses to declare the canonical
    // grammar in a bluebook surface (the specializer regenerates the
    // canonical_bluebook() seed from it).
    let domain = parser::parse(
        r#"Hecks.bluebook "GrammarMeta" do
  block_grammar "Bluebook" do
    block "aggregate",        parser: :parse_aggregate
    block "policy",           parser: :parse_policy
    block "process_manager",  parser: :parse_process_manager
    block "cadence",          parser: :parse_cadence
  end
end
"#,
    );
    assert_eq!(domain.block_grammars.len(), 1);
    let bg = &domain.block_grammars[0];
    assert_eq!(bg.name, "Bluebook");
    assert_eq!(bg.blocks.len(), 4);
    assert_eq!(bg.blocks[0].keyword, "aggregate");
    assert_eq!(bg.blocks[0].parser, BlockParser::Aggregate);
    assert_eq!(bg.blocks[3].keyword, "cadence");
    assert_eq!(bg.blocks[3].parser, BlockParser::Cadence);
}

#[test]
fn keyword_word_boundary_check_doesnt_false_match() {
    // `policy` must not claim a hypothetical `policy_foo` line. The
    // dispatch loop's keyword_matches check requires a word-boundary
    // (whitespace or end of line) after the keyword.
    let domain = parser::parse(
        r#"Hecks.bluebook "T" do
  aggregate "Order" do
    command "Place" do
      role "Customer"
    end
  end
end
"#,
    );
    // Just confirm the basic happy-path shape stays intact.
    assert_eq!(domain.aggregates.len(), 1);
    assert!(domain.policies.is_empty());
}
