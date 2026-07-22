//! The KEYSTONE proof of "finish event sourcing" : an event_sourced aggregate's
//! RICH deltas (a Money value object) land in the Log FAITHFULLY — as structured
//! JSON — and the projection fold reconstructs the live value EXACTLY.
//!
//! Before this arc, record_event_append stored each delta as `value.to_string()`,
//! and `Value`'s Display renders a Map as "{2 fields}" — so a deposit's balance
//! delta recorded the STRING "{2 fields}", the cents gone. `verify-projection`
//! only showed green because it compared that garbage to the store's OWN Display
//! garbage. The Log could not be a source of truth for any aggregate with value
//! objects. This test would FAIL on that old path : the delta carries no "cents",
//! and the fold cannot reconstruct the Money.
//!
//! Boots the REAL framework substrate (via boot_with_framework_dir), so the
//! AppendLog adapter actually persists — the in-process environment slice 1 used.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use storehouse::runtime::projection_fold::fold_event_log;
use storehouse::runtime::{value_from_json_str, AggregateState, Runtime, Value};
use storehouse::{corpus_loader, embed};

fn conception() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..").join("hecks_conception")
}

fn copy_dir(from: &Path, to: &Path) {
    std::fs::create_dir_all(to).unwrap();
    for entry in std::fs::read_dir(from).unwrap_or_else(|e| panic!("read {:?}: {}", from, e)) {
        let entry = entry.unwrap();
        if entry.file_type().unwrap().is_file() {
            std::fs::copy(entry.path(), to.join(entry.file_name())).unwrap();
        }
    }
}

// A rich aggregate : a Money balance (a nested value object) that a Deposit grows
// by Money arithmetic — the exact shape (banking's Account) the fold must rebuild.
const VAULT: &str = r#"Hecks.bluebook "Vault", version: "2026.07.21.1" do
  aggregate "Vault" do
    attribute :balance, Money
    value_object "Money" do
      attribute :cents,    Integer, default: 0
      attribute :currency, Currency
    end
    value_object "Currency" do
      attribute :code, String, default: "USD"
    end
    command "OpenVault" do
      role "System"
      emits "VaultOpened"
    end
    command "Deposit" do
      role "System"
      reference_to Vault
      attribute :amount, Money
      then_set :balance, increment: :amount
      emits "Deposited"
    end
  end
end
"#;

const VAULT_HEX: &str = r#"Hecks.hecksagon "Vault" do
  Vault::Vault.persisted_by("Heki")
  Vault::Vault.event_sourced
end
"#;

fn money(cents: i64) -> Value {
    let mut c = HashMap::new();
    c.insert("code".to_string(), Value::Str("USD".to_string()));
    let mut m = HashMap::new();
    m.insert("cents".to_string(), Value::Int(cents));
    m.insert("currency".to_string(), Value::Map(c));
    Value::Map(m)
}

#[test]
fn event_sourced_money_delta_is_faithful_and_folds_back() {
    let c = conception();
    let root = std::env::temp_dir().join("es_faithful_delta_proof");
    let _ = std::fs::remove_dir_all(&root);

    // The real framework corpus so realm/store paths + the AppendLog adapter
    // resolve as in production (same set slice 1's proof copies).
    let fw = root.join("aggregates").join("framework");
    copy_dir(&c.join("aggregates/framework/adapters"), &fw.join("adapters"));
    copy_dir(&c.join("aggregates/framework/families"), &fw.join("families"));
    copy_dir(
        &c.join("aggregates/framework/event_sourcing/bluebook"),
        &fw.join("event_sourcing/bluebook"),
    );
    copy_dir(
        &c.join("aggregates/framework/hexagon/bluebook"),
        &fw.join("hexagon/bluebook"),
    );

    let vd = fw.join("vault/bluebook");
    std::fs::create_dir_all(&vd).unwrap();
    std::fs::write(vd.join("vault.bluebook"), VAULT).unwrap();
    std::fs::write(vd.join("vault.hecksagon"), VAULT_HEX).unwrap();

    let agg_dir = root.join("aggregates");
    let agg_dir_s = agg_dir.to_str().unwrap();
    let domain = corpus_loader::load_combined_domain(agg_dir_s);
    let hecksagons = embed::load_hecksagons(agg_dir_s);
    let data = root.join("data").to_string_lossy().into_owned();
    let mut rt =
        Runtime::boot_with_framework_dir(domain, Some(data), hecksagons, &agg_dir);

    // Open the vault (balance materialises {cents:0, currency:{USD}} from the VO
    // default), then deposit 5000 — balance grows to {cents:5000} via Money
    // arithmetic. Each is an event_sourced command, so each records a balance delta.
    rt.dispatch("Vault::Vault.OpenVault", HashMap::new()).expect("OpenVault");
    let mut dep = HashMap::new();
    dep.insert("vault".to_string(), Value::Str("1".to_string()));
    dep.insert("amount".to_string(), money(5000));
    rt.dispatch("Vault::Vault.Deposit", dep).expect("Deposit");

    // Live store : balance is {cents:5000}.
    let live = rt.find("Vault", "1").expect("vault exists");
    assert_eq!(live.get("balance"), &money(5000), "live store balance is Money 5000");

    // The Log : find the Vault balance deltas.
    let events = rt.all_qualified(Some("EventSourcing"), "Event");
    let field_of = |e: &AggregateState| match e.get("delta") {
        Value::Map(m) => m.get("field").map(|v| v.to_string()).unwrap_or_default(),
        _ => String::new(),
    };
    let value_of = |e: &AggregateState| match e.get("delta") {
        Value::Map(m) => m.get("value").map(|v| v.to_string()).unwrap_or_default(),
        _ => String::new(),
    };
    let balance_deltas: Vec<String> = events
        .iter()
        .filter(|e| e.get("aggregate_name").to_string() == "Vault" && field_of(e) == "balance")
        .map(|e| value_of(e))
        .collect();
    assert!(!balance_deltas.is_empty(), "the event_sourced Vault records balance deltas");

    // FAITHFUL : the deposit's balance delta is structured JSON carrying the cents,
    // NOT the lossy Display "{2 fields}". This is the whole keystone.
    assert!(
        balance_deltas.iter().any(|v| v.contains("\"cents\":5000")),
        "a balance delta must be faithful JSON with cents 5000 — got {:?} \
         (the OLD value.to_string() path would show \"{{2 fields}}\")",
        balance_deltas,
    );
    assert!(
        !balance_deltas.iter().any(|v| v == "{2 fields}"),
        "no balance delta may be the lossy Display form",
    );

    // The fold RECONSTRUCTS the live Money exactly (structural, order-independent).
    let folded = fold_event_log(&events);
    let vault_state = folded
        .get(&("Vault".to_string(), "1".to_string()))
        .expect("fold reconstructs the Vault instance");
    let reconstructed = value_from_json_str(vault_state.get("balance").expect("balance folded"));
    assert_eq!(
        reconstructed,
        money(5000),
        "the fold rebuilds balance == the live store's Money — the Log is derivable",
    );

    // The EVENT-ROW : one first-class fact per emitted domain event — event_name
    // set, delta empty. The governable/lineage fact. It is logged ALONGSIDE the
    // delta rows (dual-write) and the fold SKIPS it (proven above : balance still
    // reconstructs exactly despite these rows existing).
    let event_name_of = |e: &AggregateState| match e.get("event_name") {
        Value::Map(m) => m.get("value").map(|v| v.to_string()).unwrap_or_default(),
        _ => String::new(),
    };
    let deposited = events
        .iter()
        .find(|e| event_name_of(e) == "Deposited")
        .expect("a first-class Deposited event-row is logged (event_name set)");
    // Faithful payload : the Money rides command.inputs as structured JSON.
    let inputs = match deposited.get("command") {
        Value::Map(m) => m.get("inputs").map(|v| v.to_string()).unwrap_or_default(),
        _ => String::new(),
    };
    assert!(inputs.contains("\"cents\":5000"), "event-row payload is faithful : {inputs}");
    // Runtime provenance stamped.
    let rv = match deposited.get("runtime_version") {
        Value::Map(m) => m.get("value").map(|v| v.to_string()).unwrap_or_default(),
        _ => String::new(),
    };
    assert!(!rv.is_empty(), "event-row carries runtime_version provenance");
    // PROVENANCE : the event-row carries the SUBJECT bluebook's declared version
    // (Vault's header `version: "2026.07.21.1"`) — parsed onto the aggregate
    // (Aggregate.bluebook_version) and threaded to the writer. Before increment 1
    // the parser DROPPED the header's version:, so this field was always empty.
    let bv = match deposited.get("bluebook_version") {
        Value::Map(m) => m.get("value").map(|v| v.to_string()).unwrap_or_default(),
        _ => String::new(),
    };
    assert_eq!(bv, "2026.07.21.1", "event-row carries the subject bluebook's declared version");

    // GOVERNABILITY : the event-row stamps the REAL actor + the verdict this
    // command was admitted under. OpenVault/Deposit declare `role "System"` and
    // carry no principal, so the dispatch is System-origin : actor "system" and a
    // POPULATED verdict VO — allowed "true", policy_id "system-origin". Before this
    // slice the writer stamped a bare hardcoded actor and NO verdict at all, so
    // these assertions bite : verdict would be absent.
    let str_field = |e: &AggregateState, k: &str| match e.get(k) {
        Value::Map(m) => m.get("value").map(|v| v.to_string()).unwrap_or_default(),
        Value::Str(s) => s.clone(),
        other => other.to_string(),
    };
    assert_eq!(str_field(deposited, "actor"), "system", "system-origin event-row records the system actor");
    let verdict_field = |e: &AggregateState, k: &str| match e.get("verdict") {
        Value::Map(m) => m.get(k).map(|v| v.to_string()).unwrap_or_default(),
        _ => String::new(),
    };
    assert_eq!(verdict_field(deposited, "allowed"), "true", "verdict.allowed is true for a recorded success");
    assert_eq!(
        verdict_field(deposited, "policy_id"), "system-origin",
        "a System-origin dispatch is admitted by origin — the verdict VO is populated, not absent",
    );

    let _ = std::fs::remove_dir_all(&root);
}
