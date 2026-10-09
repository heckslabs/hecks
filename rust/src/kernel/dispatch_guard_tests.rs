//! The refusal guards and the save/emit tail, driven through a small hand-written record. The
//! generated domains' own coverage lives in the Ruby conformance specs, which a Rust-side
//! mutation run cannot see; these pin the kernel's behaviour where `cargo mutants` can.

use super::*;
use crate::kernel::InMemoryRepository;

#[derive(Clone, Debug)]
struct Item {
    qty: i64,
    state: String,
    ok: bool,
}

impl Fielded for Item {
    fn field(&self, name: &str) -> Option<Field<'_>> {
        match name {
            "qty" => Some(Field::Value(Value::Int(self.qty))),
            "state" => Some(Field::Value(Value::Str(self.state.clone()))),
            "ok" => Some(Field::Value(Value::Bool(self.ok))),
            _ => None,
        }
    }
}

#[derive(Clone, Debug)]
struct Acct {
    balance: i64,
    status: String,
    ok: bool,
    items: Vec<Item>,
}

fn item(state: &str, qty: i64) -> Item {
    Item { qty, state: state.to_string(), ok: true }
}

fn acct() -> Acct {
    Acct { balance: 10, status: "open".to_string(), ok: true, items: vec![item("a", 1), item("b", 2)] }
}

impl Fielded for Acct {
    fn field(&self, name: &str) -> Option<Field<'_>> {
        match name {
            "balance" => Some(Field::Value(Value::Int(self.balance))),
            "status" => Some(Field::Value(Value::Str(self.status.clone()))),
            "ok" => Some(Field::Value(Value::Bool(self.ok))),
            _ => None,
        }
    }
    fn items(&self, name: &str) -> Option<Vec<Field<'_>>> {
        (name == "items").then(|| self.items.iter().map(|i| Field::Nested(i as &dyn Fielded)).collect())
    }
}

impl ToJson for Acct {
    fn to_json(&self) -> Json {
        Json::obj(vec![("balance", Json::int(self.balance)), ("status", Json::str(self.status.clone()))])
    }
}

impl SetProjectedField for Acct {
    fn set_projected_field(&mut self, _name: &'static str, _value: Option<Value>) {}
}

fn rule(description: &'static str, field: &'static str) -> InvariantSpec {
    InvariantSpec { description, expr: Expr::Lookup(field) }
}

fn given(description: &'static str, field: &'static str) -> GivenSpec {
    GivenSpec { description, expr: Expr::Lookup(field), corrects_event: None }
}

fn corrects_given(event: &'static str, field: &'static str) -> GivenSpec {
    GivenSpec { description: "unused", expr: Expr::Lookup(field), corrects_event: Some(event) }
}

fn no_invariants() -> InvariantSet {
    InvariantSet { aggregate: vec![], entities: vec![] }
}

fn refusal_of(result: Result<(), Refusal>) -> (&'static str, String) {
    let refusal = result.unwrap_err();
    (refusal.kind(), refusal.to_string())
}

fn closed() -> Acct {
    Acct { ok: false, ..acct() }
}

#[test]
fn an_aggregate_invariant_that_does_not_hold_refuses_naming_the_aggregate() {
    let set = InvariantSet { aggregate: vec![rule("never frozen", "ok")], entities: vec![] };

    assert_eq!(refusal_of(enforce_invariants(&closed(), "Acct", &set)), ("InvariantViolation", "Acct refused — never frozen".to_string()));
    assert!(enforce_invariants(&acct(), "Acct", &set).is_ok());
}

#[test]
fn the_first_failing_aggregate_invariant_is_the_one_named() {
    let set = InvariantSet { aggregate: vec![rule("first", "ok"), rule("second", "ok")], entities: vec![] };

    assert_eq!(refusal_of(enforce_invariants(&closed(), "Acct", &set)).1, "Acct refused — first");
}

#[test]
fn an_entity_invariant_refuses_the_element_that_breaks_it_and_names_the_entity() {
    let set = InvariantSet {
        aggregate: vec![],
        entities: vec![EntityInvariants { name: "Item", list_field: "items", specs: vec![rule("stays ok", "ok")], nested: vec![] }],
    };
    let mut record = acct();
    assert!(enforce_invariants(&record, "Acct", &set).is_ok());

    record.items[1].ok = false;
    assert_eq!(refusal_of(enforce_invariants(&record, "Acct", &set)), ("InvariantViolation", "Item refused — stays ok".to_string()));
}

#[test]
fn an_entity_invariant_over_a_list_the_owner_does_not_have_passes() {
    let set = InvariantSet {
        aggregate: vec![],
        entities: vec![EntityInvariants { name: "Item", list_field: "no_such_list", specs: vec![rule("never read", "missing")], nested: vec![] }],
    };

    assert!(enforce_invariants(&acct(), "Acct", &set).is_ok());
}

#[test]
fn a_given_that_does_not_hold_refuses_with_its_description() {
    let givens = [given("must be open", "ok")];

    assert_eq!(
        refusal_of(enforce_givens(&closed(), &NoFields, &givens, "Close", "D::Acct", "a1")),
        ("GivenNotMet", "Close refused — must be open".to_string())
    );
    assert!(enforce_givens(&acct(), &NoFields, &givens, "Close", "D::Acct", "a1").is_ok());
}

#[test]
fn a_failing_corrects_given_refuses_as_nothing_to_correct_naming_the_record() {
    let givens = [corrects_given("Opened", "ok")];

    assert_eq!(
        refusal_of(enforce_givens(&closed(), &NoFields, &givens, "Fix", "D::Acct", "a1")),
        ("NothingToCorrect", "Fix refused — corrects Opened, but D::Acct #a1 has never emitted it".to_string())
    );
}

#[test]
fn a_transition_from_an_allowed_state_passes_and_from_any_other_refuses() {
    let check = TransitionCheck { field: "status", from_states: &["open", "held"] };

    assert!(admissible_transition(&acct(), Some(&check), "Close").is_ok());
    let shut = Acct { status: "closed".to_string(), ..acct() };
    let (kind, text) = refusal_of(admissible_transition(&shut, Some(&check), "Close"));
    assert_eq!(kind, "LifecycleRefused");
    assert!(text.contains("closed"), "{text}");
}

#[test]
fn no_transition_declared_admits_anything() {
    assert!(admissible_transition(&acct(), None, "Close").is_ok());
}

#[test]
fn a_lifecycle_field_that_is_missing_or_not_a_string_is_a_type_mismatch() {
    let numeric = TransitionCheck { field: "balance", from_states: &["open"] };
    let absent = TransitionCheck { field: "nope", from_states: &["open"] };

    assert_eq!(refusal_of(admissible_transition(&acct(), Some(&numeric), "Close")).0, "TypeMismatch");
    assert_eq!(refusal_of(admissible_transition(&acct(), Some(&absent), "Close")).0, "TypeMismatch");
}

#[test]
fn an_ensures_that_does_not_hold_after_the_mutation_refuses() {
    let ensures = [EnsuresSpec { description: "stays ok", expr: Expr::Lookup("ok") }];

    assert_eq!(
        refusal_of(enforce_ensures(&closed(), &acct(), &NoFields, &ensures, "Close")),
        ("EnsuresNotMet", "Close refused — stays ok".to_string())
    );
    assert!(enforce_ensures(&acct(), &acct(), &NoFields, &ensures, "Close").is_ok());
}

struct Run {
    repo: InMemoryRepository<Acct>,
    mutations: Vec<MutationRecord>,
}

fn fresh() -> Run {
    Run { repo: InMemoryRepository::new(), mutations: vec![] }
}

fn create(id: &str, state_independent: bool) -> Hydrate<'static, Acct> {
    Hydrate::Create { id: id.to_string(), build: Box::new(acct), state_independent }
}

fn act(id: &str) -> Hydrate<'static, Acct> {
    Hydrate::Act { id: id.to_string() }
}

fn run_dispatch(
    run: &mut Run,
    hydrate: Hydrate<'_, Acct>,
    givens: &[GivenSpec],
    transition: Option<TransitionCheck>,
    ensures: &[EnsuresSpec],
    invariants: &InvariantSet,
) -> Result<(Acct, Vec<Event>), Refusal> {
    dispatch(
        &mut run.repo,
        hydrate,
        "Fund",
        "D::Acct",
        "Acct",
        "id",
        &NoFields,
        givens,
        transition,
        |record: &mut Acct| {
            record.balance += 5;
            Ok(())
        },
        ensures,
        invariants,
        &["Funded", "Audited"],
        Json::str("payload"),
        &mut run.mutations,
        vec![],
        Ok(()),
    )
}

#[test]
fn a_creating_dispatch_saves_the_record_records_the_mutation_and_emits_in_declared_order() {
    let mut run = fresh();

    let (record, events) = run_dispatch(&mut run, create("a1", false), &[], None, &[], &no_invariants()).unwrap();

    assert_eq!(record.balance, 15);
    assert_eq!(run.repo.find("a1").unwrap().balance, 15);
    assert_eq!(run.mutations.len(), 1);
    let saved = &run.mutations[0];
    assert_eq!((saved.aggregate.as_str(), saved.id.as_str(), saved.operation), ("D::Acct", "a1", "save"));
    assert_eq!(saved.state, record.to_json());
    let emitted: Vec<(&str, &str, &str)> = events.iter().map(|e| (e.name.as_str(), e.aggregate.as_str(), e.id.as_str())).collect();
    assert_eq!(emitted, [("Funded", "D::Acct", "a1"), ("Audited", "D::Acct", "a1")]);
    assert_eq!(events[0].payload, Json::str("payload"));
}

#[test]
fn acting_on_an_existing_record_succeeds_and_does_not_trip_the_deferred_existence_check() {
    let mut run = fresh();
    run.repo.save("a1", acct());

    let (record, _) = run_dispatch(&mut run, act("a1"), &[], None, &[], &no_invariants()).unwrap();

    assert_eq!(record.balance, 15);
    assert_eq!(run.repo.find("a1").unwrap().balance, 15);
}

#[test]
fn acting_on_a_missing_record_is_not_found() {
    let mut run = fresh();

    let refusal = run_dispatch(&mut run, act("ghost"), &[], None, &[], &no_invariants()).unwrap_err();

    assert_eq!(refusal.kind(), "NotFound");
    assert!(run.mutations.is_empty());
}

#[test]
fn a_creating_dispatch_over_an_existing_identity_is_already_exists_in_both_check_positions() {
    for state_independent in [false, true] {
        let mut run = fresh();
        run.repo.save("a1", acct());

        let refusal = run_dispatch(&mut run, create("a1", state_independent), &[], None, &[], &no_invariants()).unwrap_err();

        assert_eq!(refusal.kind(), "AlreadyExists", "state_independent={state_independent}");
        assert!(run.mutations.is_empty(), "nothing saved when refused");
    }
}

#[test]
fn a_creating_dispatch_with_a_blank_identity_is_not_found() {
    let mut run = fresh();

    assert_eq!(run_dispatch(&mut run, create("", false), &[], None, &[], &no_invariants()).unwrap_err().kind(), "NotFound");
}

// Each guard stored over a record that fails it, so the refusal is the guard's own.
fn refused_by(run: &mut Run, givens: &[GivenSpec], transition: Option<TransitionCheck>, ensures: &[EnsuresSpec], invariants: &InvariantSet) -> &'static str {
    run.repo.save("a1", closed());
    let kind = run_dispatch(run, act("a1"), givens, transition, ensures, invariants).unwrap_err().kind();
    assert_eq!(run.repo.find("a1").unwrap().balance, 10, "a refused dispatch leaves the stored record alone");
    assert!(run.mutations.is_empty());
    kind
}

#[test]
fn dispatch_refuses_at_each_guard_before_saving() {
    assert_eq!(refused_by(&mut fresh(), &[given("open", "ok")], None, &[], &no_invariants()), "GivenNotMet");

    let held_only = TransitionCheck { field: "status", from_states: &["held"] };
    assert_eq!(refused_by(&mut fresh(), &[], Some(held_only), &[], &no_invariants()), "LifecycleRefused");

    let ensures = [EnsuresSpec { description: "ok", expr: Expr::Lookup("ok") }];
    assert_eq!(refused_by(&mut fresh(), &[], None, &ensures, &no_invariants()), "EnsuresNotMet");

    let invariants = InvariantSet { aggregate: vec![rule("ok", "ok")], entities: vec![] };
    assert_eq!(refused_by(&mut fresh(), &[], None, &[], &invariants), "InvariantViolation");
}

#[test]
fn the_tenant_boundary_check_refuses_before_the_write() {
    let mut run = fresh();

    let refusal = dispatch(
        &mut run.repo,
        create("a1", false),
        "Fund",
        "D::Acct",
        "Acct",
        "id",
        &NoFields,
        &[],
        None,
        |_: &mut Acct| Ok(()),
        &[],
        &no_invariants(),
        &[],
        Json::Null,
        &mut run.mutations,
        vec![],
        Err(Refusal::Unauthorized("cross-tenant".to_string())),
    )
    .unwrap_err();

    assert_eq!(refusal.kind(), "Unauthorized");
    assert!(run.repo.find("a1").is_none());
}

// ---- the element half ----

fn entity_call(
    record: &mut Acct,
    matches: impl Fn(&Item) -> bool,
    givens: &[GivenSpec],
    transition: Option<TransitionCheck>,
    ensures: &[EnsuresSpec],
) -> Result<(), Refusal> {
    apply_entity_command(
        record,
        "a1",
        |r: &Acct| &r.items,
        |r: &mut Acct| &mut r.items,
        matches,
        "Bump",
        "D::Acct",
        "Acct",
        "Item",
        "state",
        "\"b\"",
        &NoFields,
        givens,
        transition,
        |element: &mut Item| {
            element.qty += 100;
            element.state = "bumped".to_string();
            Ok(())
        },
        ensures,
        true,
    )
}

fn is_b(i: &Item) -> bool {
    i.state == "b"
}

#[test]
fn an_entity_command_mutates_only_the_located_element() {
    let mut record = acct();

    entity_call(&mut record, is_b, &[], None, &[]).unwrap();

    assert_eq!((record.items[0].qty, record.items[0].state.as_str()), (1, "a"));
    assert_eq!((record.items[1].qty, record.items[1].state.as_str()), (102, "bumped"));
}

#[test]
fn an_entity_command_naming_no_element_is_not_found_and_changes_nothing() {
    let mut record = acct();

    let (kind, _) = refusal_of(entity_call(&mut record, |i| i.state == "zzz", &[], None, &[]));

    assert_eq!(kind, "NotFound");
    assert_eq!(record.items[1].qty, 2);
}

#[test]
fn an_entity_given_is_read_off_the_element_and_refuses_when_it_fails() {
    let mut record = acct();
    record.items[1].ok = false;

    let (kind, text) = refusal_of(entity_call(&mut record, is_b, &[given("item ok", "ok")], None, &[]));

    assert_eq!((kind, text.as_str()), ("GivenNotMet", "Bump refused — item ok"));
    assert_eq!(record.items[1].qty, 2, "refused before the mutation");
}

#[test]
fn an_entity_corrects_given_is_asked_of_the_parent_and_never_of_the_element() {
    // The parent is ok, so the corrects given passes; the element's own `ok` then decides the
    // ordinary given.
    let mut record = acct();
    record.items[1].ok = false;
    let givens = [corrects_given("Opened", "ok"), given("item ok", "ok")];
    assert_eq!(refusal_of(entity_call(&mut record, is_b, &givens, None, &[])).0, "GivenNotMet");

    // Parent not ok: the corrects given refuses, naming the parent record.
    let mut record = closed();
    let (kind, text) = refusal_of(entity_call(&mut record, is_b, &[corrects_given("Opened", "ok")], None, &[]));
    assert_eq!(kind, "NothingToCorrect");
    assert_eq!(text, "Bump refused — corrects Opened, but D::Acct #a1 has never emitted it");

    // `balance` is on the parent only. Read off the element it would refuse, so passing proves
    // a corrects given is skipped by the element loop.
    let mut record = acct();
    assert!(entity_call(&mut record, is_b, &[corrects_given("Opened", "balance")], None, &[]).is_ok());
}

#[test]
fn an_entity_transition_checks_the_element_state() {
    let mut record = acct();
    let wrong = TransitionCheck { field: "state", from_states: &["a"] };
    assert_eq!(refusal_of(entity_call(&mut record, is_b, &[], Some(wrong), &[])).0, "LifecycleRefused");

    let right = TransitionCheck { field: "state", from_states: &["b"] };
    assert!(entity_call(&mut record, is_b, &[], Some(right), &[]).is_ok());
}

#[test]
fn an_entity_ensures_sees_the_settled_element_and_refuses_when_it_fails() {
    let ensures = [EnsuresSpec { description: "ok", expr: Expr::Lookup("ok") }];
    let mut record = acct();
    assert!(entity_call(&mut record, is_b, &[], None, &ensures).is_ok());

    let mut record = acct();
    record.items[1].ok = false;
    let (kind, text) = refusal_of(entity_call(&mut record, is_b, &[], None, &ensures));
    assert_eq!((kind, text.as_str()), ("EnsuresNotMet", "Bump refused — ok"));
}

#[allow(clippy::too_many_arguments)]
fn run_dispatch_entity(run: &mut Run, parent_id: &str, matches: impl Fn(&Item) -> bool, new_qty: i64) -> Result<(Acct, Vec<Event>), Refusal> {
    dispatch_entity(
        &mut run.repo,
        parent_id,
        |r: &Acct| &r.items,
        |r: &mut Acct| &mut r.items,
        matches,
        "Bump",
        "D::Acct",
        "Acct",
        "id",
        "Item",
        "state",
        "\"b\"",
        &NoFields,
        &[],
        None,
        move |element: &mut Item| {
            element.qty = new_qty;
            Ok(())
        },
        &[],
        &no_invariants(),
        &["Bumped"],
        Json::Null,
        &mut run.mutations,
        vec![],
    )
}

#[test]
fn dispatch_entity_hydrates_the_parent_mutates_the_element_saves_and_emits() {
    let mut run = fresh();
    run.repo.save("a1", acct());

    let (record, events) = run_dispatch_entity(&mut run, "a1", is_b, 99).unwrap();

    assert_eq!(record.items[1].qty, 99);
    assert_eq!(run.repo.find("a1").unwrap().items[1].qty, 99);
    assert_eq!(run.mutations.len(), 1);
    assert_eq!(events.iter().map(|e| e.name.as_str()).collect::<Vec<_>>(), ["Bumped"]);
}

#[test]
fn dispatch_entity_over_a_missing_parent_is_not_found() {
    let mut run = fresh();

    assert_eq!(run_dispatch_entity(&mut run, "ghost", is_b, 99).unwrap_err().kind(), "NotFound");
}
