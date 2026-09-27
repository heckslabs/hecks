// `to_json().from_json()` must reproduce an equal record, including `Json::Null` for unset
// Option fields; `Store::from_seed` would otherwise silently corrupt seeded state.
// Compiles only when banking is the generated domain (bin/project_rust examples/banking).
#![cfg(feature = "banking")]

use rust::generated::active::{dispatch_by_name, Store};
use rust::kernel::{Json, MutationRecord, Refusal, Repository};

fn register_customer(store: &mut Store, reference: &str) {
    let args = Json::obj(vec![
        ("reference", Json::obj(vec![("value", Json::str(reference))])),
        ("name", Json::obj(vec![("given", Json::str("Ada")), ("family", Json::str("Lovelace"))])),
        ("email", Json::obj(vec![("address", Json::str("ada@example.com"))])),
    ]);
    let mut mutations: Vec<MutationRecord> = Vec::new();
    dispatch_by_name(store, "Banking::Customer.Register", &args, None, None, &mut mutations)
        .expect("registering a fresh customer should succeed");
}

#[test]
fn a_dispatched_record_round_trips_through_to_json_and_from_json() {
    let mut store = Store::new();
    register_customer(&mut store, "CUST-RT-0001");

    let original = store.customer.find("CUST-RT-0001").expect("just-registered customer should be findable");
    let json = original.to_json();
    let parsed = rust::generated::banking::customer::Customer::from_json(&json)
        .expect("from_json should parse to_json's own output");

    assert_eq!(original, parsed, "round-tripping a record through to_json/from_json should reproduce it exactly");
}

// An attribute genuinely left `None` must round-trip as `None`, not a refusal.
#[test]
fn an_unset_optional_field_round_trips_as_none_not_a_refusal() {
    let mut store = Store::new();
    register_customer(&mut store, "CUST-RT-0002");

    let args = Json::obj(vec![
        ("customer", Json::str("CUST-RT-0002")),
        ("number", Json::obj(vec![("value", Json::str("acct-rt-1"))])),
        ("kind", Json::obj(vec![("name", Json::str("current"))])),
        ("daily_limit", Json::obj(vec![("cents", Json::int(50000))])),
    ]);
    let mut mutations: Vec<MutationRecord> = Vec::new();
    dispatch_by_name(&mut store, "Banking::Account.Open", &args, None, None, &mut mutations)
        .expect("opening a fresh account should succeed");

    let original = store.account.find("acct-rt-1").expect("just-opened account should be findable");
    let json = original.to_json();
    let parsed = rust::generated::banking::account::Account::from_json(&json)
        .expect("from_json should parse to_json's own output");

    assert_eq!(original, parsed, "an account with unset optional fields should still round-trip exactly");
}

// Entities in a `Vec` (SafeDepositBox.visits) round-trip, with and without an optional note.
#[test]
fn a_record_holding_entities_with_and_without_an_optional_field_round_trips() {
    let mut store = Store::new();
    register_customer(&mut store, "CUST-RT-0003");

    let rent_args = Json::obj(vec![
        ("customer", Json::str("CUST-RT-0003")),
        ("branch_code", Json::obj(vec![("value", Json::str("downtown"))])),
        ("box_number", Json::obj(vec![("value", Json::int(12))])),
        ("size", Json::obj(vec![("value", Json::str("medium"))])),
    ]);
    let mut mutations: Vec<MutationRecord> = Vec::new();
    dispatch_by_name(&mut store, "Banking::SafeDepositBox.Rent", &rent_args, None, None, &mut mutations)
        .expect("renting a fresh box should succeed");

    let visit_with_note = Json::obj(vec![
        ("branch_code", Json::obj(vec![("value", Json::str("downtown"))])),
        ("box_number", Json::obj(vec![("value", Json::int(12))])),
        ("date", Json::obj(vec![("value", Json::str("2026-08-08"))])),
        ("sequence", Json::obj(vec![("value", Json::int(1))])),
        ("note", Json::obj(vec![("text", Json::str("routine"))])),
    ]);
    dispatch_by_name(&mut store, "Banking::SafeDepositBox.LogVisit", &visit_with_note, None, None, &mut mutations)
        .expect("logging a visit with a note should succeed");

    // note left unset
    let visit_without_note = Json::obj(vec![
        ("branch_code", Json::obj(vec![("value", Json::str("downtown"))])),
        ("box_number", Json::obj(vec![("value", Json::int(12))])),
        ("date", Json::obj(vec![("value", Json::str("2026-08-08"))])),
        ("sequence", Json::obj(vec![("value", Json::int(2))])),
    ]);
    dispatch_by_name(&mut store, "Banking::SafeDepositBox.LogVisit", &visit_without_note, None, None, &mut mutations)
        .expect("logging a visit without a note should succeed");

    let original = store.safedepositbox.find("downtown:12").expect("just-rented box should be findable");
    assert_eq!(original.visits.len(), 2, "both visits should be recorded before the round-trip is even attempted");

    let json = original.to_json();
    let parsed = rust::generated::banking::safedepositbox::SafeDepositBox::from_json(&json)
        .expect("from_json should parse to_json's own output, including its nested Vec<Visit>");

    assert_eq!(original, parsed, "a record holding entities (with and without their own optional field) should round-trip exactly");
}

// `Store::from_seed` must invert `instances()`, or a seeded Store diverges from the original.
#[test]
fn a_seeded_store_matches_the_store_it_was_seeded_from() {
    let mut original_store = Store::new();
    register_customer(&mut original_store, "CUST-RT-0004");
    let open_args = Json::obj(vec![
        ("customer", Json::str("CUST-RT-0004")),
        ("number", Json::obj(vec![("value", Json::str("acct-rt-2"))])),
        ("kind", Json::obj(vec![("name", Json::str("savings"))])),
        ("daily_limit", Json::obj(vec![("cents", Json::int(10000))])),
    ]);
    let mut mutations: Vec<MutationRecord> = Vec::new();
    dispatch_by_name(&mut original_store, "Banking::Account.Open", &open_args, None, None, &mut mutations)
        .expect("opening a fresh account should succeed");

    let dump = Json::Object(original_store.instances());
    let seeded_store = Store::from_seed(&dump).expect("seeding from a real instances() dump should never refuse");

    assert_eq!(
        Json::Object(seeded_store.instances()),
        Json::Object(original_store.instances()),
        "a Store seeded from another Store's own instances() dump should produce the identical dump back"
    );

    // Usable, not just equal: the seeded store sees state it never registered itself.
    let credit_args = Json::obj(vec![
        ("number", Json::obj(vec![("value", Json::str("acct-rt-2"))])),
        ("amount", Json::obj(vec![("cents", Json::int(500)), ("currency", Json::str("USD"))])),
        ("narrative", Json::obj(vec![("text", Json::str("test deposit"))])),
    ]);
    let mut seeded_store = seeded_store;
    let outcome: Result<_, Refusal> =
        dispatch_by_name(&mut seeded_store, "Banking::Account.Credit", &credit_args, None, None, &mut mutations);
    assert!(outcome.is_ok(), "a command against seeded state should dispatch normally: {outcome:?}");
}
