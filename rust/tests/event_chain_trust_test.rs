//! TRUST (Stage 5) — the Log is tamper-EVIDENT, not merely append-only.
//!
//! Stage 4 made the Log authoritative : state is derived from it. That raises the
//! stakes on the Log itself — if it can be quietly edited, then so can every
//! answer the system gives. Each entry hashes its own content TOGETHER WITH the
//! previous entry's hash, so the entries of one shard form a chain : edit, drop or
//! reorder any entry and it stops re-deriving.
//!
//! HONEST SCOPE. What these tests prove is that a CARELESS change is caught : an
//! entry edited in place, and a link that no longer names its predecessor. What
//! they do NOT prove — and what the mechanism does not provide — is protection
//! against a DETERMINED rewriter, who can simply recompute every hash after the
//! entry they changed. That needs a cryptographic digest AND an anchor beyond the
//! rewriter's reach (a signed or externally-witnessed head). Neither is asserted
//! here, because neither is true yet.

mod realm_fixture;

use std::collections::HashMap;
use storehouse::runtime::{AggregateState, Runtime, Value};

const TALLY: &str = r#"Hecks.bluebook "Tally" do
  core
  aggregate "Counter" do
    identified_by :name
    attribute :name, Name
    attribute :hits, Hits, default: "0"
    value_object "Name" do
      attribute :value, String
    end
    value_object "Hits" do
      attribute :value, String
    end
    command "Bump" do
      role "System"
      attribute :name, Name
      attribute :hits, Hits
      then_set :hits, to: :hits
      emits "Bumped"
    end
  end
end
"#;

const TALLY_HEX: &str = r#"Hecks.hecksagon "Tally" do
  Tally::Counter.persisted_by("Heki")
  Tally::Counter.event_sourced
end
"#;

fn bump(rt: &mut Runtime, name: &str, hits: &str) {
    let mut attrs = HashMap::new();
    attrs.insert("name".to_string(), Value::Str(name.to_string()));
    attrs.insert("hits".to_string(), Value::Str(hits.to_string()));
    rt.dispatch("Tally::Counter.Bump", attrs).expect("Bump dispatches");
}

fn breaks(rt: &Runtime) -> Vec<serde_json::Value> {
    let attrs = HashMap::new();
    rt.resolve_query("ChainIntact", &attrs)
        .get("state")
        .and_then(|s| s.as_array())
        .cloned()
        .unwrap_or_default()
}

fn kinds(rows: &[serde_json::Value]) -> Vec<String> {
    rows.iter()
        .filter_map(|r| r.get("break").and_then(|b| b.as_str()).map(String::from))
        .collect()
}

/// Every event-log entry, as the framework collaborator holds them.
fn events(rt: &mut Runtime) -> Vec<AggregateState> {
    rt.framework_mut()
        .all_qualified(Some("EventSourcing"), "Event")
        .into_iter()
        .cloned()
        .collect()
}

#[test]
fn an_untouched_log_re_derives_completely() {
    let (mut rt, root) = realm_fixture::boot_realm("es_chain_intact", "tally", TALLY, TALLY_HEX);
    bump(&mut rt, "c1", "1");
    bump(&mut rt, "c1", "2");
    bump(&mut rt, "c2", "5");

    let evs = events(&mut rt);
    assert!(evs.len() >= 3, "expected a populated log, got {} entries", evs.len());

    // Every entry carries a chain, and exactly one starts it.
    let hashed = evs
        .iter()
        .filter(|e| !matches!(e.get("entry_hash"), Value::Str(s) if s.is_empty()))
        .count();
    assert_eq!(hashed, evs.len(), "every entry must carry an entry_hash");

    let found = breaks(rt.framework_mut());
    assert!(found.is_empty(), "an untouched log must re-derive completely, got {found:#?}");

    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn editing_an_entry_is_caught() {
    let (mut rt, root) = realm_fixture::boot_realm("es_chain_edited", "tally", TALLY, TALLY_HEX);
    bump(&mut rt, "c1", "1");
    bump(&mut rt, "c1", "2");
    assert!(breaks(rt.framework_mut()).is_empty(), "precondition : intact before tampering");

    // Rewrite one entry's recorded delta — the classic quiet edit : make the Log
    // say a different thing happened, leaving its hash alone.
    let target = events(&mut rt)
        .into_iter()
        .find(|e| matches!(e.get("delta"), Value::Map(m) if !m.get("field").map(|f| f.to_string().is_empty()).unwrap_or(true)))
        .expect("a delta entry to tamper with");
    let id = match target.get("event_id") {
        Value::Str(s) => s.clone(),
        other => other.to_string(),
    };
    let mut edited = target.clone();
    let mut delta = HashMap::new();
    delta.insert("field".to_string(), Value::Str("hits".to_string()));
    delta.insert("value".to_string(), Value::Str("\"99999\"".to_string()));
    edited.set("delta", Value::Map(delta));
    let key = storehouse::runtime::repo_key(Some("EventSourcing"), "Event");
    rt.framework_mut()
        .repositories
        .get_mut(&key)
        .expect("Event repo")
        .seed_record(edited);

    let found = breaks(rt.framework_mut());
    let ks = kinds(&found);
    assert!(
        ks.contains(&"content".to_string()),
        "an edited entry must break its own content hash — got {found:#?}",
    );
    assert!(
        found.iter().any(|b| b.get("event_id").and_then(|v| v.as_str()) == Some(id.as_str())),
        "the break must name the entry that was edited ({id}) — got {found:#?}",
    );

    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn a_missing_predecessor_breaks_the_link() {
    let (mut rt, root) = realm_fixture::boot_realm("es_chain_dropped", "tally", TALLY, TALLY_HEX);
    bump(&mut rt, "c1", "1");
    bump(&mut rt, "c1", "2");
    bump(&mut rt, "c1", "3");
    assert!(breaks(rt.framework_mut()).is_empty(), "precondition : intact before tampering");

    // Induce the OBSERVABLE CONSEQUENCE of an excised entry : the entry after it no
    // longer names its predecessor. (Deleting the record outright needs a heki
    // WriteContext ; what a verifier can ever see is this broken link, so this is
    // the condition that matters.) Note the victim entry still hashes to its own
    // content in isolation — only the CHAIN reveals the gap, which is exactly why
    // entries are chained rather than merely checksummed row by row.
    let mut ordered = events(&mut rt);
    ordered.sort_by_key(|e| match e.get("sequence") {
        Value::Int(i) => *i,
        Value::Map(m) => m.get("value").and_then(|v| v.as_int()).unwrap_or(0),
        _ => 0,
    });
    let mut victim = ordered[ordered.len() / 2].clone();
    victim.set("prev_hash", Value::Str("0000000000000000".to_string()));
    let key = storehouse::runtime::repo_key(Some("EventSourcing"), "Event");
    rt.framework_mut()
        .repositories
        .get_mut(&key)
        .expect("Event repo")
        .seed_record(victim);

    let found = breaks(rt.framework_mut());
    assert!(
        kinds(&found).contains(&"link".to_string()),
        "a dropped entry must break the chain LINK of the entry after it — got {found:#?}",
    );

    let _ = std::fs::remove_dir_all(&root);
}
