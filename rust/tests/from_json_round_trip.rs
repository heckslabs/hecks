// Verifies the mechanical claim `emit_from_json_state`'s own header
// (rust/project/json_codec.rb) makes: it's the TRUE inverse of
// `emit_to_json_flat` for a real aggregate record — `to_json().
// from_json()` should reproduce an equal struct, round-tripping through
// the exact "key always present, Json::Null for an unset Option field"
// shape `to_json` actually emits (not the "key absent" shape
// command-args `from_json` expects — see that method's own header on
// why it's a distinct emitter from `emit_from_json_flat`). Exists for
// `Store::from_seed`'s own sake: if this round trip doesn't hold, a
// host seeding prior state back into a fresh Store (rather than
// replaying full command history) would silently corrupt it.
//
// Only compiles/runs when the banking domain is the currently-generated
// one (`bin/project_rust examples/banking`) — Cargo.toml's own
// per-domain feature gate, kept in sync by bin/project_rust. Uses a
// REAL dispatched record (via `dispatch_by_name`), not a hand-built
// struct literal — the actual shape a `Store` produces, not a
// synthetic approximation of it.
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
    dispatch_by_name(store, "Banking::Customer.Register", &args, None, &mut mutations)
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

// THE SHARPER PROOF — an attribute genuinely left `None` (not just
// "happens to be Some for every field a Register call sets") must
// round-trip too, since that's the entire reason emit_from_json_state
// exists as a SEPARATE emitter: `standing`/`status` are set by
// Register, but nothing about a freshly-created Customer sets every
// possible optional field on every aggregate in this domain — Account's
// own optional fields are a cleaner, more direct proof: `AtmCard`
// issuance leaves fields unset that a later command fills in.
#[test]
fn an_unset_optional_field_round_trips_as_none_not_a_refusal() {
    let mut store = Store::new();
    register_customer(&mut store, "CUST-RT-0002");

    let args = Json::obj(vec![
        ("customer_id", Json::str("CUST-RT-0002")),
        ("number", Json::obj(vec![("value", Json::str("acct-rt-1"))])),
        ("kind", Json::obj(vec![("name", Json::str("current"))])),
        ("daily_limit", Json::obj(vec![("cents", Json::int(50000))])),
    ]);
    let mut mutations: Vec<MutationRecord> = Vec::new();
    dispatch_by_name(&mut store, "Banking::Account.Open", &args, None, &mut mutations)
        .expect("opening a fresh account should succeed");

    let original = store.account.find("acct-rt-1").expect("just-opened account should be findable");
    let json = original.to_json();
    let parsed = rust::generated::banking::account::Account::from_json(&json)
        .expect("from_json should parse to_json's own output");

    assert_eq!(original, parsed, "an account with unset optional fields should still round-trip exactly");
}

// THE ENTITY CASE SPECIFICALLY — never exercised before this pass
// (entities had no from_json at all). SafeDepositBox.visits is a
// `Vec<Visit>`, so the RECORD's own from_json only round-trips
// correctly if `Visit::from_json` (also newly generated) does too, one
// visit logged with a note and one left `None` — the same "unset
// optional round-trips as None" proof, one level of nesting deeper,
// plus the entity's own lifecycle field.
#[test]
fn a_record_holding_entities_with_and_without_an_optional_field_round_trips() {
    let mut store = Store::new();
    register_customer(&mut store, "CUST-RT-0003");

    let rent_args = Json::obj(vec![
        ("customer_id", Json::str("CUST-RT-0003")),
        ("branch_code", Json::obj(vec![("value", Json::str("downtown"))])),
        ("box_number", Json::obj(vec![("value", Json::int(12))])),
        ("size", Json::obj(vec![("value", Json::str("medium"))])),
    ]);
    let mut mutations: Vec<MutationRecord> = Vec::new();
    dispatch_by_name(&mut store, "Banking::SafeDepositBox.Rent", &rent_args, None, &mut mutations)
        .expect("renting a fresh box should succeed");

    let visit_with_note = Json::obj(vec![
        ("branch_code", Json::obj(vec![("value", Json::str("downtown"))])),
        ("box_number", Json::obj(vec![("value", Json::int(12))])),
        ("date", Json::obj(vec![("value", Json::str("2026-08-08"))])),
        ("sequence", Json::obj(vec![("value", Json::int(1))])),
        ("note", Json::obj(vec![("text", Json::str("routine"))])),
    ]);
    dispatch_by_name(&mut store, "Banking::SafeDepositBox.LogVisit", &visit_with_note, None, &mut mutations)
        .expect("logging a visit with a note should succeed");

    // note LEFT UNSET — the entity-level version of the same proof
    // above, and the one this test exists for.
    let visit_without_note = Json::obj(vec![
        ("branch_code", Json::obj(vec![("value", Json::str("downtown"))])),
        ("box_number", Json::obj(vec![("value", Json::int(12))])),
        ("date", Json::obj(vec![("value", Json::str("2026-08-08"))])),
        ("sequence", Json::obj(vec![("value", Json::int(2))])),
    ]);
    dispatch_by_name(&mut store, "Banking::SafeDepositBox.LogVisit", &visit_without_note, None, &mut mutations)
        .expect("logging a visit without a note should succeed");

    let original = store.safedepositbox.find("downtown:12").expect("just-rented box should be findable");
    assert_eq!(original.visits.len(), 2, "both visits should be recorded before the round-trip is even attempted");

    let json = original.to_json();
    let parsed = rust::generated::banking::safedepositbox::SafeDepositBox::from_json(&json)
        .expect("from_json should parse to_json's own output, including its nested Vec<Visit>");

    assert_eq!(original, parsed, "a record holding entities (with and without their own optional field) should round-trip exactly");
}

// THE ACTUAL POINT OF ALL THE ABOVE — `Store::from_seed` is what a host
// (rust/host) would call instead of `Store::new()` to stop replaying
// full command history: seed a fresh Store from a prior `instances()`
// dump, then dispatch is one call, not a full replay. If `instances()`
// and `from_seed` aren't true inverses, a seeded Store silently
// diverges from the real one it's meant to stand in for.
#[test]
fn a_seeded_store_matches_the_store_it_was_seeded_from() {
    let mut original_store = Store::new();
    register_customer(&mut original_store, "CUST-RT-0004");
    let open_args = Json::obj(vec![
        ("customer_id", Json::str("CUST-RT-0004")),
        ("number", Json::obj(vec![("value", Json::str("acct-rt-2"))])),
        ("kind", Json::obj(vec![("name", Json::str("savings"))])),
        ("daily_limit", Json::obj(vec![("cents", Json::int(10000))])),
    ]);
    let mut mutations: Vec<MutationRecord> = Vec::new();
    dispatch_by_name(&mut original_store, "Banking::Account.Open", &open_args, None, &mut mutations)
        .expect("opening a fresh account should succeed");

    let dump = Json::Object(original_store.instances());
    let seeded_store = Store::from_seed(&dump).expect("seeding from a real instances() dump should never refuse");

    assert_eq!(
        Json::Object(seeded_store.instances()),
        Json::Object(original_store.instances()),
        "a Store seeded from another Store's own instances() dump should produce the identical dump back"
    );

    // AND IT'S USABLE, not just structurally equal — dispatching a NEW
    // command against the seeded store should see the seeded state
    // (the customer it never itself registered), the entire reason a
    // host would seed instead of replay in the first place.
    let credit_args = Json::obj(vec![
        ("number", Json::obj(vec![("value", Json::str("acct-rt-2"))])),
        ("amount", Json::obj(vec![("cents", Json::int(500)), ("currency", Json::str("USD"))])),
        ("narrative", Json::obj(vec![("text", Json::str("test deposit"))])),
    ]);
    let mut seeded_store = seeded_store;
    let outcome: Result<_, Refusal> =
        dispatch_by_name(&mut seeded_store, "Banking::Account.Credit", &credit_args, None, &mut mutations);
    assert!(outcome.is_ok(), "a command against seeded state should dispatch normally: {outcome:?}");
}
