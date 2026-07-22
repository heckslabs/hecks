//! GOVERNABILITY : the Log records WHO acted, under WHICH policy. An event_sourced
//! command dispatched by a real AGENT principal (not System) records a first-class
//! event-row whose `actor` is the agent's auth id and whose `verdict` VO carries the
//! role it held and the Policy that permitted it — captured at the entry gate before
//! the principal is stripped, threaded to the synchronous Log writer.
//!
//! Before this slice the writer hardcoded `actor "system"` and stamped no verdict, so
//! a recorded SUCCESS lost its actor entirely (only DENIALS, in Governance::Violation,
//! knew who was refused). This test boots the REAL framework substrate WITH the
//! Authorization + Storehouse-gating chapters, turns the PDP gate on, permits agent
//! `alice` to Deposit, and proves the Deposited event-row attributes the deposit to
//! her under her permit.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use storehouse::runtime::{AggregateState, Runtime, Value};
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

const VAULT: &str = r#"Hecks.bluebook "Vault" do
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

fn a(p: &[(&str, &str)]) -> HashMap<String, Value> {
    p.iter().map(|(k, v)| (k.to_string(), Value::Str(v.to_string()))).collect()
}

#[test]
fn agent_dispatch_records_real_actor_and_verdict_on_the_event_row() {
    let c = conception();
    let root = std::env::temp_dir().join("es_actor_verdict_proof");
    let _ = std::fs::remove_dir_all(&root);

    // The real framework corpus — event_sourcing + hexagon + adapters/families for
    // the AppendLog persistence, PLUS the Authorization (Policy/RoleAssignment) and
    // Storehouse (Gate) chapters so the PDP gate + Permit resolve as in production.
    let fw = root.join("aggregates").join("framework");
    copy_dir(&c.join("aggregates/framework/adapters"), &fw.join("adapters"));
    copy_dir(&c.join("aggregates/framework/families"), &fw.join("families"));
    copy_dir(
        &c.join("aggregates/framework/event_sourcing/bluebook"),
        &fw.join("event_sourcing/bluebook"),
    );
    copy_dir(&c.join("aggregates/framework/hexagon/bluebook"), &fw.join("hexagon/bluebook"));
    copy_dir(&c.join("aggregates/framework/authorization"), &fw.join("authorization"));
    copy_dir(
        &c.join("aggregates/storehouse/bluebook"),
        &root.join("aggregates/storehouse/bluebook"),
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
    let mut rt = Runtime::boot_with_framework_dir(domain, Some(data), hecksagons, &agg_dir);

    // Governance setup, as System (admitted by origin) : turn the PDP gate on, give
    // alice a role, and permit her to Deposit. deny-by-default means she can act only
    // through this explicit grant — so a matching verdict.policy_id is unambiguous.
    rt.dispatch(
        "Storehouse::Gate.Declare",
        a(&[("name", "authorize"), ("phase", "before"), ("check", "authorize"), ("pattern", "*"), ("order", "30")]),
    )
    .expect("declare authorize gate");
    rt.dispatch(
        "Authorization::RoleAssignment.Assign",
        a(&[("auth_identity_id", "alice"), ("role_name", "editor")]),
    )
    .expect("assign alice the editor role");
    rt.dispatch(
        "Authorization::Policy.Permit",
        a(&[("id", "alice-deposit"), ("principal", "alice"), ("action", "Deposit"), ("resource", "*"), ("condition", "-"), ("expires_at", "-")]),
    )
    .expect("permit alice to Deposit");

    // Open the vault as System (setup), then Deposit AS ALICE — the governed act.
    rt.dispatch("Vault::Vault.OpenVault", HashMap::new()).expect("OpenVault");
    let mut dep = a(&[("vault", "1")]);
    dep.insert("amount".to_string(), money(5000));
    dep.insert("actor_kind".to_string(), Value::Str("agent".to_string()));
    dep.insert("actor_auth_id".to_string(), Value::Str("alice".to_string()));
    rt.dispatch("Vault::Vault.Deposit", dep).expect("alice deposits");

    // The deposit applied — balance is Money 5000.
    let live = rt.find("Vault", "1").expect("vault exists");
    assert_eq!(live.get("balance"), &money(5000), "alice's deposit applied");

    // The Deposited event-row : find it, and read its governability fields.
    let events = rt.all_qualified(Some("EventSourcing"), "Event");
    let event_name_of = |e: &AggregateState| match e.get("event_name") {
        Value::Map(m) => m.get("value").map(|v| v.to_string()).unwrap_or_default(),
        _ => String::new(),
    };
    let deposited = events
        .iter()
        .find(|e| event_name_of(e) == "Deposited")
        .expect("a first-class Deposited event-row is logged");

    let str_field = |e: &AggregateState, k: &str| match e.get(k) {
        Value::Map(m) => m.get("value").map(|v| v.to_string()).unwrap_or_default(),
        Value::Str(s) => s.clone(),
        other => other.to_string(),
    };
    let verdict_field = |e: &AggregateState, k: &str| match e.get("verdict") {
        Value::Map(m) => m.get(k).map(|v| v.to_string()).unwrap_or_default(),
        _ => String::new(),
    };

    // The GOVERNABILITY payoff : the recorded success names its actor + verdict.
    assert_eq!(str_field(deposited, "actor"), "alice", "the event-row attributes the deposit to alice, not `system`");
    assert_eq!(verdict_field(deposited, "allowed"), "true", "a recorded success is allowed");
    assert_eq!(verdict_field(deposited, "role"), "editor", "the verdict carries the role alice held");
    assert_eq!(verdict_field(deposited, "policy_id"), "alice-deposit", "the verdict names the Policy that permitted her");

    let _ = std::fs::remove_dir_all(&root);
}
