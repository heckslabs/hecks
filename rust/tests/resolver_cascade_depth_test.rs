// [antibody-exempt: Rust runtime integration test — booted-runtime cascade/quote-handling, not expressible as .behaviors ; same category as compute/llm dispatcher tests]
//! resolver-on-cascade + depth-guard regression gate.
//!
//! Two invariants of `driven_adapter_resolver::resolve_driven_adapters`, the
//! engine that lets a driven adapter's follow-on event trigger the NEXT
//! adapter (Claim.Acquire -> Lease.Grant -> worktree_create) :
//!
//!   1. FORWARD CHAIN : a follow-on event re-activates the resolver, so a
//!      multi-hop chain runs end-to-end. Proven with a 3-aggregate chain
//!      Alpha -> Beta -> Gamma : Gamma is reached ONLY if the resolver
//!      recurses past the first hop (this test fails if the recursion is
//!      removed).
//!
//!   2. CYCLE SAFETY : a cyclic adapter graph terminates at
//!      MAX_CASCADE_DEPTH instead of running forever. The recursion is
//!      call-stack-bounded, so a regressed guard overflows-and-aborts
//!      loudly here — never a silent CI hang.

use storehouse::hecksagon_parser;
use storehouse::parser;
use storehouse::runtime::{Runtime, Value};
use std::collections::HashMap;

fn s(v: &str) -> Value { Value::Str(v.to_string()) }
fn attrs(pairs: &[(&str, Value)]) -> HashMap<String, Value> {
    pairs.iter().map(|(k, v)| (k.to_string(), v.clone())).collect()
}

// ---- Forward chain : Alpha -> Beta -> Gamma -------------------------------
const CHAIN_BB: &str = r#"Hecks.bluebook "Chain" do
  category "framework"
  aggregate "Alpha" do
    identified_by :name
    attribute :name, String
    command "Fire" do
      role "System"
      attribute :name, String
      then_set :name, to: :name
      emits "AlphaFired"
    end
  end
  aggregate "Beta" do
    identified_by :name
    attribute :name, String
    command "Make" do
      role "System"
      attribute :name, String
      then_set :name, to: :name
      emits "BetaMade"
    end
  end
  aggregate "Gamma" do
    identified_by :name
    attribute :name, String
    command "Make" do
      role "System"
      attribute :name, String
      then_set :name, to: :name
      emits "GammaMade"
    end
  end
end"#;

const CHAIN_HX: &str = r#"Hecks.hecksagon "Chain" do
  adapter "AlphaToBeta" do
    driven on "Chain::Alpha.AlphaFired" do |event|
      dispatch "Chain::Beta.Make", name: "{name}"
    end
  end
  adapter "BetaToGamma" do
    driven on "Chain::Beta.BetaMade" do |event|
      dispatch "Chain::Gamma.Make", name: "{name}"
    end
  end
end"#;

#[test]
fn forward_chain_recurses_past_the_first_hop() {
    let domain = parser::parse(CHAIN_BB);
    let hex = hecksagon_parser::parse(CHAIN_HX);
    let mut rt = Runtime::boot_with_hecksagons(domain, None, vec![hex]);

    rt.dispatch("Fire", attrs(&[("name", s("x1"))])).unwrap();

    // Hop 1 (Alpha -> Beta) worked even before resolver-on-cascade.
    assert_eq!(rt.all("Beta").len(), 1, "Beta made by hop 1");
    // Hop 2 (Beta -> Gamma) only fires if the resolver re-activates on the
    // CASCADED BetaMade event — the whole point of resolver-on-cascade.
    assert_eq!(
        rt.all("Gamma").len(), 1,
        "Gamma must be created by the 2nd hop — resolver-on-cascade regressed if this is 0",
    );
}

// ---- Cycle safety : Ping.Beat -> Beated -> dispatch Beat -> ... ------------
const CYCLE_BB: &str = r#"Hecks.bluebook "Loop" do
  category "framework"
  aggregate "Ping" do
    identified_by :name
    attribute :name, String
    command "Beat" do
      role "System"
      attribute :name, String
      then_set :name, to: :name
      emits "Beated"
    end
  end
end"#;

const CYCLE_HX: &str = r#"Hecks.hecksagon "Loop" do
  adapter "ReBeat" do
    driven on "Loop::Ping.Beated" do |event|
      dispatch "Loop::Ping.Beat", name: "{name}"
    end
  end
end"#;

#[test]
fn cyclic_adapter_terminates_at_depth_bound() {
    let domain = parser::parse(CYCLE_BB);
    let hex = hecksagon_parser::parse(CYCLE_HX);
    let mut rt = Runtime::boot_with_hecksagons(domain, None, vec![hex]);

    // ReBeat re-dispatches Beat on every Beated event — an infinite cycle
    // bounded ONLY by MAX_CASCADE_DEPTH. Reaching the assertion proves the
    // cascade terminated. If the depth guard regresses, the call-stack
    // recursion overflows and aborts the test binary loudly (never a hang).
    let res = rt.dispatch("Beat", attrs(&[("name", s("p1"))]));
    assert!(res.is_ok(), "bounded cyclic dispatch returned err: {:?}", res.err());
    assert_eq!(rt.all("Ping").len(), 1, "one Ping record after the bounded cycle");
}

// ---- Greedy run-string extraction : inner double-quotes survive ----------
#[test]
fn run_leaf_preserves_inner_double_quotes_in_cmd() {
    // A run/result_into leaf whose command contains double-quotes (e.g. a
    // gh --jq filter) must parse with the inner quotes INTACT — the greedy
    // first-to-last-quote extraction, not first-to-next.
    let src = r#"Hecks.hecksagon "Plan" do
  adapter "PrCheck" do
    driven on "Plan::Story.StoryChecksRequested" do |event|
      run "gh pr view sq/x --jq 'if .state==\"OPEN\" then empty else halt_error(1) end'", result_into: "Plan::Story.RecordPrMergeableCheckResult"
    end
  end
end"#;
    let hex = hecksagon_parser::parse(src);
    let h = &hex.driven_adapters[0].handlers[0];
    assert_eq!(h.checks.len(), 1, "one check leaf");
    let c = &h.checks[0];
    assert_eq!(c.result_into, "Plan::Story.RecordPrMergeableCheckResult");
    assert!(c.cmd.contains("\"OPEN\""), "inner double-quotes must survive: got {}", c.cmd);
    assert!(c.cmd.contains("halt_error(1) end"), "full filter must survive: got {}", c.cmd);
    assert!(!c.cmd.contains("result_into"), "cmd must not swallow result_into");
}

// ---- create-keyword (reference_to retirement step 1) ----------------------
// Proves `create "X"` sets Command.creates and that the FLAG, not the name
// heuristic, drives creation in dispatch. The corpus uses zero `create`
// markers today, so these are the only thing exercising the new path.
const CREATE_KW_BB: &str = r#"Hecks.bluebook "Widgets" do
  aggregate "Widget", "a widget" do
    identified_by :name
    attribute :name, String
    create "Spawn" do
      reference_to(Widget)
      emits "WidgetSpawned"
    end
    command "Poke" do
      reference_to(Widget)
      emits "WidgetPoked"
    end
  end
end
"#;

#[test]
fn create_keyword_builds_factory_node_command_stays_command() {
    // First-class factories phase 1 : the transitional `create` keyword
    // (and the `factory` keyword) build a Factory NODE in
    // aggregate.factories — the #729 creates bool is gone. A plain
    // command stays in aggregate.commands.
    let domain = parser::parse(CREATE_KW_BB);
    let agg = domain.aggregates.iter().find(|a| a.name == "Widget").unwrap();
    let spawn = agg.factories.iter().find(|f| f.name == "Spawn");
    assert!(spawn.is_some(), "`create \"Spawn\"` must build a Factory node");
    assert!(spawn.unwrap().produces.is_none(),
        "no produces: kwarg → the factory births its enclosing aggregate");
    assert!(agg.commands.iter().all(|c| c.name != "Spawn"),
        "a factory must NOT appear in the parsed IR's commands");
    let poke = agg.commands.iter().find(|c| c.name == "Poke");
    assert!(poke.is_some(), "`command \"Poke\"` stays a Command");
    assert!(agg.factories.iter().all(|f| f.name != "Poke"),
        "a command must NOT appear in factories");
}

#[test]
fn create_flag_drives_minting_independent_of_name_heuristic() {
    // "Spawn" matches no name heuristic ; it mints only because creates=true.
    let domain = parser::parse(CREATE_KW_BB);
    let mut rt = Runtime::boot_with_hecksagons(domain, None, vec![]);
    let spawned = rt.dispatch("Widgets::Widget.Spawn", attrs(&[("name", s("w1"))]));
    assert!(spawned.is_ok(), "create-keyword Spawn should mint, got: {:?}", spawned);
    // creates=false sibling, no id, no heuristic match -> must not silently mint.
    let poked = rt.dispatch("Widgets::Widget.Poke", attrs(&[]));
    assert!(poked.is_err(), "command Poke must not mint, got: {:?}", poked);
}
