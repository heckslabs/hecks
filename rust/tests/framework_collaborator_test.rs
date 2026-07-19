//! STEP ZERO for CARD-framework-substrate-service : the kernel writes the event
//! Log through an injected FRAMEWORK COLLABORATOR, not by requiring the
//! EventSourcing chapter to have been merged into the user's domain.
//!
//! The bug this closes : `record_event_append` used to open with
//!
//!     if !self.repositories.contains_key(&es_key) { return; }
//!
//! "no Log unless EventSourcing is in MY domain". So a domain that explicitly
//! declared `event_sourced` in its hecksagon, and did everything right, still
//! silently wrote nothing if it was booted from a single bluebook. Silently is
//! the operative word — no error, no warning, just no Log. This test is that
//! exact configuration : ONE bluebook, no corpus, no EventSourcing chapter
//! anywhere in the domain.
//!
//! It also pins the two structural properties the collaborator depends on :
//! the user's domain stays clean (nothing is grafted into it), and the
//! recursion is bounded (the collaborator has no collaborator of its own).

use std::collections::HashMap;
use storehouse::runtime::{Runtime, Value};
use storehouse::{hecksagon_parser, parser};

/// One bluebook. No EventSourcing chapter, no corpus, no framework dir.
const LEDGER: &str = r#"Hecks.bluebook "Ledger" do
  aggregate "Entry" do
    identified_by :entry_id
    attribute :entry_id, EntryId
    attribute :memo,     Memo
    value_object "EntryId" do
      attribute :value, String
    end
    value_object "Memo" do
      attribute :value, String
    end
    command "Post" do
      role "System"
      attribute :entry_id, EntryId
      attribute :memo,     Memo
      then_set :memo, to: :memo
      emits "Posted"
    end
  end
end
"#;

/// The whole wiring : persistence plus the persistence+ event-sourcing toggle.
const LEDGER_HEX: &str = r#"Hecks.hecksagon "Ledger" do
  Ledger::Entry.persisted_by("Heki")
  Ledger::Entry.event_sourced
end
"#;

fn boot(dir: &std::path::Path) -> Runtime {
    Runtime::boot_with_hecksagons(
        parser::parse(LEDGER),
        Some(dir.to_string_lossy().into_owned()),
        vec![hecksagon_parser::parse(LEDGER_HEX)],
    )
}

fn post(rt: &mut Runtime, id: &str, memo: &str) {
    let mut attrs = HashMap::new();
    attrs.insert("entry_id".to_string(), Value::Str(id.to_string()));
    attrs.insert("memo".to_string(), Value::Str(memo.to_string()));
    rt.dispatch("Ledger::Entry.Post", attrs).expect("Post dispatches");
}

#[test]
fn a_single_bluebook_boot_writes_the_log_through_the_collaborator() {
    let dir = std::env::temp_dir().join("fw_collab_step_zero");
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();

    let mut rt = boot(&dir);

    // Precondition : the EventSourcing chapter is NOT in this domain. If this
    // ever fails, something grafted it in and the test below proves nothing.
    assert!(
        !rt.domain.aggregates.iter().any(|a| a.name == "Event"),
        "the user's domain must NOT contain EventSourcing::Event — that is the \
         whole point (aggregates: {:?})",
        rt.domain.aggregates.iter().map(|a| &a.name).collect::<Vec<_>>(),
    );

    post(&mut rt, "e-1", "first");

    // The Log lives in the collaborator.
    let fw = rt.framework.as_ref().expect("the collaborator booted on first append");
    let events = fw.all_qualified(Some("EventSourcing"), "Event");
    assert!(
        !events.is_empty(),
        "a single-bluebook boot carrying `event_sourced` must write its deltas \
         to the Log — this is the case that silently wrote NOTHING before the \
         collaborator existed",
    );
    assert!(
        events.iter().any(|e| e.get("aggregate_name").to_string().contains("Entry")),
        "the recorded events belong to the user's aggregate (got {:?})",
        events.iter().map(|e| e.get("aggregate_name").to_string()).collect::<Vec<_>>(),
    );

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn the_users_domain_stays_clean_and_the_recursion_is_bounded() {
    let dir = std::env::temp_dir().join("fw_collab_bounds");
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();

    let mut rt = boot(&dir);
    post(&mut rt, "e-1", "first");

    // 1. Nothing was grafted. The served surface renders the domain, so this is
    //    what keeps framework substrate off a user's page — by construction,
    //    with no filter to maintain.
    let names: Vec<String> = rt.domain.aggregates.iter().map(|a| a.name.clone()).collect();
    assert_eq!(
        names,
        vec!["Entry".to_string()],
        "the user's domain is exactly what its author wrote",
    );

    // 2. The recursion terminates : the collaborator has no collaborator. If it
    //    ever booted one, every Append would boot another runtime and the
    //    process would spiral.
    let fw = rt.framework.as_ref().expect("collaborator booted");
    assert!(
        fw.framework.is_none(),
        "the collaborator must not boot a collaborator of its own — that is what \
         bounds the recursion",
    );

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn no_directive_means_no_log_even_with_the_collaborator_available() {
    // The collaborator makes the Log REACHABLE ; it must not make it automatic.
    // Without `event_sourced` (and without the global env override) a domain
    // still writes nothing — otherwise every runtime in the corpus would start
    // event-sourcing itself by surprise.
    let dir = std::env::temp_dir().join("fw_collab_no_directive");
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();

    let mut rt = Runtime::boot_with_hecksagons(
        parser::parse(LEDGER),
        Some(dir.to_string_lossy().into_owned()),
        vec![hecksagon_parser::parse(
            "Hecks.hecksagon \"Ledger\" do\n  Ledger::Entry.persisted_by(\"Heki\")\nend\n",
        )],
    );
    post(&mut rt, "e-1", "first");

    let logged = rt
        .framework
        .as_ref()
        .map(|fw| fw.all_qualified(Some("EventSourcing"), "Event").len())
        .unwrap_or(0);
    assert_eq!(
        logged, 0,
        "no `event_sourced` directive means no Log — reachability is not consent",
    );

    let _ = std::fs::remove_dir_all(&dir);
}
