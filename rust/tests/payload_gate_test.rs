//! Payload gate integration tests — the ACL at the dispatch threshold.
//!
//! Proves the 2026-07-18 ruling : "the domain can always assume its
//! payloads are valid." A value-object invariant judges the INCOMING
//! attrs before hydration/mutation ; a refusal touches nothing — no
//! record, no event. Mirrors the live -5-fee corruption caught in the
//! ToolShed workshop demo (inbox/PLAN-payload-gate-acl.md).

use std::collections::HashMap;
use storehouse::parser;
use storehouse::runtime::{Runtime, RuntimeError, Value};

fn boot(source: &str) -> Runtime {
    Runtime::boot(parser::parse(source))
}

fn attrs(pairs: &[(&str, Value)]) -> HashMap<String, Value> {
    pairs.iter().map(|(k, v)| (k.to_string(), v.clone())).collect()
}

fn s(val: &str) -> Value {
    Value::Str(val.to_string())
}

const TOOLSHED: &str = r##"Hecks.bluebook "ToolShed" do
  aggregate "Tool" do
    description "A tool on the shelf"
    attribute :name, ToolName
    attribute :daily_fee, Fee

    value_object "ToolName" do
      attribute :value, String
    end

    value_object "Fee" do
      attribute :cents, Integer
      invariant "must be non-negative" do
        cents >= 0
      end
    end

    command "AddTool" do
      role "Owner"
      attribute :name, ToolName
      attribute :daily_fee, Fee
    end
  end
end"##;

#[test]
fn inline_vo_invariant_parses_and_bites() {
    // The one-liner form (inbox.bluebook's CommitSha) : the whole block on
    // one line. Caught by the parity contract the day VO invariants joined
    // the canonical IR.
    let src = r##"Hecks.bluebook "Inline" do
  aggregate "Card" do
    attribute :sha, CommitSha
    value_object "CommitSha" do
      attribute :value, String
      invariant "non-empty" do value.length > 0 end
    end
    command "Stamp" do
      role "Owner"
      attribute :sha, CommitSha
    end
  end
end"##;
    let domain = parser::parse(src);
    let vo = domain.aggregates[0].value_objects.iter().find(|v| v.name == "CommitSha").unwrap();
    assert_eq!(vo.invariants.len(), 1);
    assert_eq!(vo.invariants[0].expression, "value.length > 0");

    let mut rt = Runtime::boot(domain);
    match rt.dispatch("Stamp", attrs(&[("sha", s(""))])) {
        Err(RuntimeError::PayloadInvariantViolation { field, .. }) => assert_eq!(field, "sha"),
        other => panic!("empty sha must be refused, got {:?}", other),
    }
    rt.dispatch("Stamp", attrs(&[("sha", s("abc123"))])).expect("valid sha passes");
}

#[test]
fn float_bounds_judge_correctly() {
    // `value >= 0.0 && value <= 1.0` — float literals must resolve
    // numerically (language.bluebook's Confidence caught the evaluator
    // treating `1.0` as a phantom field → Null → 0).
    let src = r##"Hecks.bluebook "Conf" do
  aggregate "Pattern" do
    attribute :confidence, Confidence
    value_object "Confidence" do
      attribute :value, Float
      invariant "must be between 0 and 1" do
        value >= 0.0 && value <= 1.0
      end
    end
    command "Register" do
      role "System"
      attribute :confidence, Confidence
    end
  end
end"##;
    let mut rt = Runtime::boot(parser::parse(src));
    rt.dispatch("Register", attrs(&[("confidence", s("1.0"))]))
        .expect("1.0 is within [0,1]");
    rt.dispatch("Register", attrs(&[("confidence", s("0.5"))]))
        .expect("0.5 is within [0,1]");
    match rt.dispatch("Register", attrs(&[("confidence", s("1.5"))])) {
        Err(RuntimeError::PayloadInvariantViolation { field, .. }) => assert_eq!(field, "confidence"),
        other => panic!("1.5 must be refused, got {:?}", other),
    }
}

#[test]
fn unjudgeable_predicate_passes_unjudged() {
    // Rich Ruby (assignment + .split + block) is beyond the interpreter —
    // the gate must pass it rather than refuse by incomprehension
    // (codegen's four-segment phrase invariant). The Ruby runtime, where
    // invariants are live Procs, enforces these.
    let src = r##"Hecks.bluebook "Phrases" do
  aggregate "Emitter" do
    attribute :phrase, BusPhrase
    value_object "BusPhrase" do
      attribute :value, String
      invariant "must be four segments" do
        parts = value.split("::")
        parts.length == 4
      end
    end
    command "Emit" do
      role "System"
      attribute :phrase, BusPhrase
    end
  end
end"##;
    let mut rt = Runtime::boot(parser::parse(src));
    rt.dispatch("Emit", attrs(&[("phrase", s("a::b::C::D"))]))
        .expect("unjudgeable predicate must not refuse a valid phrase");
}

#[test]
fn vo_invariants_survive_parsing() {
    let domain = parser::parse(TOOLSHED);
    let fee = domain.aggregates[0]
        .value_objects
        .iter()
        .find(|v| v.name == "Fee")
        .expect("Fee VO parsed");
    assert_eq!(fee.invariants.len(), 1);
    assert_eq!(fee.invariants[0].name, "must be non-negative");
    assert_eq!(fee.invariants[0].expression, "cents >= 0");
}

#[test]
fn negative_fee_refused_with_zero_state_touch() {
    let mut rt = boot(TOOLSHED);
    let result = rt.dispatch(
        "AddTool",
        attrs(&[("name", s("bolt")), ("daily_fee", s("-5"))]),
    );
    match result {
        Err(RuntimeError::PayloadInvariantViolation { name, field, value, .. }) => {
            assert_eq!(name, "must be non-negative");
            assert_eq!(field, "daily_fee");
            assert_eq!(value, "-5");
        }
        other => panic!("expected PayloadInvariantViolation, got {:?}", other),
    }
    // Zero state touch : no record minted, no event emitted.
    assert!(rt.all("Tool").is_empty(), "refusal must not mint a record");
    assert!(rt.event_bus.events().is_empty(), "refusal must not emit events");
}

#[test]
fn valid_fee_passes_the_gate() {
    let mut rt = boot(TOOLSHED);
    let result = rt
        .dispatch(
            "AddTool",
            attrs(&[("name", s("bolt")), ("daily_fee", s("200"))]),
        )
        .expect("valid payload dispatches");
    assert_eq!(result.aggregate_type, "Tool");
    assert_eq!(rt.all("Tool").len(), 1);
}

#[test]
fn zero_boundary_value_passes() {
    let mut rt = boot(TOOLSHED);
    rt.dispatch(
        "AddTool",
        attrs(&[("name", s("free")), ("daily_fee", s("0"))]),
    )
    .expect("cents >= 0 admits zero");
}

#[test]
fn absent_attr_passes_the_invariant_gate() {
    // Absence is the REQUIRED gate's concern (phase B), not the
    // invariant's — an omitted fee must not be judged as 0 or refused.
    let mut rt = boot(TOOLSHED);
    rt.dispatch("AddTool", attrs(&[("name", s("bolt"))]))
        .expect("absent VO attr passes the invariant gate");
}

// --- Phase B : required attributes (explicit opt-in) ---

const REQUIRED_SHED: &str = r##"Hecks.bluebook "ReqShed" do
  aggregate "Tool" do
    description "A tool with a mandatory name"
    attribute :name, ToolName
    attribute :note, Note

    value_object "ToolName" do
      attribute :value, String
    end

    value_object "Note" do
      attribute :value, String
    end

    command "AddTool" do
      role "Owner"
      attribute :name, ToolName, required: true
      attribute :note, Note
    end
  end
end"##;

#[test]
fn required_attr_refused_when_absent() {
    let mut rt = boot(REQUIRED_SHED);
    match rt.dispatch("AddTool", attrs(&[("note", s("hi"))])) {
        Err(RuntimeError::MissingAttribute(name)) => assert_eq!(name, "name"),
        other => panic!("expected MissingAttribute, got {:?}", other),
    }
    assert!(rt.all("Tool").is_empty(), "refusal must not mint a record");
}

#[test]
fn required_attr_refused_when_empty_string() {
    let mut rt = boot(REQUIRED_SHED);
    match rt.dispatch("AddTool", attrs(&[("name", s("  "))])) {
        Err(RuntimeError::MissingAttribute(name)) => assert_eq!(name, "name"),
        other => panic!("expected MissingAttribute, got {:?}", other),
    }
}

// --- References : a command's declared ref must resolve to an id ---

const LOAN_SHED: &str = r##"Hecks.bluebook "LoanShed" do
  aggregate "Loan" do
    description "A loan that must be referenced to be returned"
    attribute :status, LoanStatus

    value_object "LoanStatus" do
      attribute :value, String
    end

    attribute :status, LoanStatus, default: "active" do
      transition "ReturnTool" => "returned"
    end

    command "OpenLoan" do
      role "Member"
    end

    command "ReturnTool" do
      role "Member"
      reference_to Loan
    end
  end
end"##;

#[test]
fn absent_reference_refused_not_minted() {
    // Before the gate : ReturnTool with no loan ref COUNTER-MINTED a
    // fresh Loan and transitioned it — a phantom born returned.
    let mut rt = boot(LOAN_SHED);
    match rt.dispatch("ReturnTool", attrs(&[])) {
        Err(RuntimeError::MissingAttribute(name)) => assert_eq!(name, "loan"),
        other => panic!("expected MissingAttribute(loan), got {:?}", other),
    }
    assert!(rt.all("Loan").is_empty(), "refusal must not mint a record");
}

#[test]
fn reference_by_snake_case_key_passes() {
    let mut rt = boot(LOAN_SHED);
    rt.dispatch("OpenLoan", attrs(&[])).expect("open");
    rt.dispatch("ReturnTool", attrs(&[("loan", s("1"))]))
        .expect("ref via snake_case key passes the gate");
}

#[test]
fn reference_by_universal_id_passes() {
    let mut rt = boot(LOAN_SHED);
    rt.dispatch("OpenLoan", attrs(&[])).expect("open");
    rt.dispatch("ReturnTool", attrs(&[("id", s("1"))]))
        .expect("universal id fallback passes the gate");
}

#[test]
fn unmarked_attr_stays_optional() {
    // The corpus dispatch style — Tools::ShellTool.Bash omitting
    // :description — must keep working : only `required: true` enforces.
    let mut rt = boot(REQUIRED_SHED);
    rt.dispatch("AddTool", attrs(&[("name", s("bolt"))]))
        .expect("unmarked :note may be omitted");
    assert_eq!(rt.all("Tool").len(), 1);
}
