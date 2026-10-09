//! Policy matching, the reaction depth ceiling, `trigger_args`' routing, and the saga legs,
//! driven through a scripted dispatch. Pinned here because the generated domains' own coverage
//! lives in Ruby conformance specs a Rust-side mutation run cannot see.

use super::*;

struct Bus {
    calls: Vec<(String, Json)>,
}

impl AggregateScan for Bus {
    fn scan(&self, aggregate: &str) -> Option<Vec<(String, Json)>> {
        (aggregate == "D::Order").then(|| vec![("o1".to_string(), Json::obj(vec![])), ("o2".to_string(), Json::obj(vec![]))])
    }
}

fn event(name: &str, aggregate: &str, id: &str, payload: Json) -> Event {
    Event { name: name.to_string(), aggregate: aggregate.to_string(), id: id.to_string(), payload, occurred_at: None, correlation: None }
}

// `D::Xfer.<Name>` emits an event called `<Name>` correlated on `ref: x1`; a verb ending in
// `Refuse` refuses; `D::Order.Ping` emits a `Ping` the `Pinger` policy answers with another.
fn script(
    bus: &mut Bus,
    verb: &str,
    args: &Json,
    _caller_role: Option<&str>,
    _caller_actor_id: Option<&str>,
    _mutations: &mut Vec<MutationRecord>,
) -> Result<Vec<Event>, Refusal> {
    bus.calls.push((verb.to_string(), args.clone()));
    if verb.ends_with("Refuse") {
        return Err(Refusal::GivenNotMet("refused".to_string()));
    }
    if let Some(name) = verb.strip_prefix("D::Xfer.") {
        return Ok(vec![event(name, "D::Xfer", "x1", Json::obj(vec![("ref", Json::str("x1"))]))]);
    }
    match verb {
        "D::Order.Place" => Ok(vec![event("Placed", "D::Order", "o1", Json::obj(vec![("amount", Json::int(5))]))]),
        "D::Order.Ping" => Ok(vec![event("Ping", "D::Order", "o1", Json::obj(vec![]))]),
        _ => Ok(vec![]),
    }
}

fn off() -> Expr {
    Expr::Bool(false)
}
fn on() -> Expr {
    Expr::Bool(true)
}

const NO_WITH: &[(&str, &str)] = &[];

const fn policy(name: &'static str, event_name: &'static str, target: &'static str) -> PolicyRule {
    PolicyRule {
        policy_name: name,
        event_name,
        event_qualifier: None,
        target_verb: target,
        where_expr: None,
        for_each: None,
        for_each_key: None,
        with_spec: NO_WITH,
    }
}

const fn cross(name: &'static str, event_name: &'static str) -> CrossDomainPolicyRule {
    CrossDomainPolicyRule { policy_name: name, event_name, event_qualifier: None, where_expr: None, target_domain: "Other", target_verb: "Other::Do" }
}

static POLICIES: [PolicyRule; 8] = [
    policy("NotifyOnPlaced", "Placed", "D::Order.Notify"),
    PolicyRule { event_qualifier: Some("Other"), ..policy("QualWrong", "Qual", "D::Order.Wrong") },
    PolicyRule { event_qualifier: Some("Order"), ..policy("QualRight", "Qual", "D::Order.Right") },
    PolicyRule { where_expr: Some(off), ..policy("GuardedOff", "Guard", "D::Order.Off") },
    PolicyRule { where_expr: Some(on), ..policy("GuardedOn", "Guard", "D::Order.On") },
    policy("Pinger", "Ping", "D::Order.Ping"),
    PolicyRule { for_each: Some("D::Order.Open"), for_each_key: Some("order_id"), ..policy("FanPing", "Fan", "D::Order.Ping") },
    PolicyRule { for_each: Some("D::Order.Missing"), ..policy("FanMissing", "FanMissing", "D::Order.Ping") },
];

static CROSS_POLICIES: [CrossDomainPolicyRule; 5] = [
    cross("XPlain", "XEvt"),
    CrossDomainPolicyRule { event_qualifier: Some("Nope"), ..cross("XQualWrong", "XQual") },
    CrossDomainPolicyRule { event_qualifier: Some("Order"), ..cross("XQualRight", "XQual") },
    CrossDomainPolicyRule { where_expr: Some(off), ..cross("XWhereOff", "XGuard") },
    CrossDomainPolicyRule { where_expr: Some(on), ..cross("XWhereOn", "XGuard") },
];

static QUERIES: [crate::kernel::QueryDef; 1] = [crate::kernel::QueryDef {
    verb: "D::Order.Open",
    aggregate: "D::Order",
    conditions: &[],
    reference_hop_conditions: &[],
    order_by: None,
    offset: None,
    limit: None,
    authorization: None,
}];

static UNDO: DispatchSpec = DispatchSpec { command_name: "Ship.Undo", with: &[("ref", WithValue::Ref("ref"))], compensates: None };

static PING_SPEC: DispatchSpec = DispatchSpec { command_name: "Order.Ping", with: &[], compensates: None };

static PROCESS_MANAGERS: [ProcessManagerDef; 3] = [
    ProcessManagerDef {
        name: "Transfer",
        correlates_by: "ref",
        starts_on: "Started",
        ends_on: "Ended",
        initial_state: "start",
        handlers: &[Handler {
            event_type: "Funded",
            from_state: "start",
            to_state: "mid",
            dispatches: &[DispatchSpec { command_name: "Ship.Go", with: &[("ref", WithValue::Ref("ref"))], compensates: Some(&UNDO) }],
        }],
    },
    ProcessManagerDef {
        name: "Risky",
        correlates_by: "ref",
        starts_on: "RiskyStarted",
        ends_on: "NeverEnds",
        initial_state: "start",
        handlers: &[
            Handler {
                event_type: "RiskyFunded",
                from_state: "start",
                to_state: "mid",
                dispatches: &[
                    DispatchSpec { command_name: "Ship.Go", with: &[("ref", WithValue::Ref("ref"))], compensates: Some(&UNDO) },
                    DispatchSpec { command_name: "Ship.Refuse", with: &[("ref", WithValue::Ref("ref"))], compensates: None },
                ],
            },
            Handler { event_type: REFUSED, from_state: "mid", to_state: "undone", dispatches: &[] },
        ],
    },
    ProcessManagerDef {
        name: "Plain",
        correlates_by: "ref",
        starts_on: "PlainStarted",
        ends_on: "NeverEnds",
        initial_state: "start",
        handlers: &[Handler {
            event_type: "PlainFunded",
            from_state: "start",
            to_state: "mid",
            dispatches: &[DispatchSpec { command_name: "Ship.Refuse", with: &[("ref", WithValue::Ref("ref"))], compensates: None }],
        }],
    },
];

fn no_key(_aggregate: &str) -> Option<&'static str> {
    None
}
fn creates(verb: &str) -> bool {
    !verb.ends_with(".Close")
}
fn identity_head(aggregate: &str) -> Option<&'static str> {
    (aggregate == "D::Order").then_some("order_id")
}
fn declared(_verb: &str) -> &'static [&'static str] {
    &["amount", "note", "tag", "order_id", "reason", "ref", "line_id", "to", "with"]
}
fn entity_head(qualified: &str) -> Option<&'static str> {
    (qualified == "D::Order.Line").then_some("line_id")
}

fn tables() -> Tables<'static> {
    Tables {
        policies: &POLICIES,
        cross_domain_policies: &CROSS_POLICIES,
        process_managers: &PROCESS_MANAGERS,
        reference_key_fn: no_key,
        queries: &QUERIES,
        command_creates_fn: creates,
        identity_head_fn: identity_head,
        command_attributes_fn: declared,
        entity_identity_head_fn: entity_head,
    }
}

struct World {
    bus: Bus,
    sagas: HashMap<(String, String), SagaInstance>,
    all_events: Vec<Event>,
    mutations: Vec<MutationRecord>,
    cross_domain: Vec<PendingCrossDomainReaction>,
    reaction_log: Vec<Json>,
    saga_log: Vec<Json>,
}

fn world() -> World {
    World {
        bus: Bus { calls: vec![] },
        sagas: HashMap::new(),
        all_events: vec![],
        mutations: vec![],
        cross_domain: vec![],
        reaction_log: vec![],
        saga_log: vec![],
    }
}

impl World {
    fn orchestrate(&mut self, verb: &str, depth: usize) -> Result<(), Refusal> {
        orchestrate(
            &mut self.bus,
            script,
            tables(),
            &mut self.sagas,
            verb,
            &Json::obj(vec![]),
            None,
            None,
            None,
            None,
            depth,
            &mut self.all_events,
            &mut self.mutations,
            &mut self.cross_domain,
            &mut self.reaction_log,
            &mut self.saga_log,
        )
    }

    fn react(&mut self, event: &Event, depth: usize) {
        react_policies(
            &mut self.bus,
            script,
            tables(),
            &mut self.sagas,
            event,
            None,
            depth,
            &mut self.all_events,
            &mut self.mutations,
            &mut self.cross_domain,
            &mut self.reaction_log,
            &mut self.saga_log,
        );
    }

    fn verbs(&self) -> Vec<&str> {
        self.bus.calls.iter().map(|(verb, _)| verb.as_str()).collect()
    }

    fn deliver_saga(&mut self, depth: usize) -> Option<bool> {
        deliver_saga_dispatch(
            &mut self.bus,
            script,
            tables(),
            &mut self.sagas,
            &PROCESS_MANAGERS[0],
            &PING_SPEC,
            "D",
            &Json::obj(vec![]),
            "x1",
            None,
            depth,
            &mut self.all_events,
            &mut self.mutations,
            &mut self.cross_domain,
            &mut self.reaction_log,
            &mut self.saga_log,
            &HashMap::new(),
            None,
        )
    }

    fn deliver_compensation(&mut self, depth: usize) {
        let entry = CompletedCompensation { command_name: "Order.Ping".to_string(), args: Json::obj(vec![]) };
        deliver_derived_compensation(
            &mut self.bus,
            script,
            tables(),
            &mut self.sagas,
            &PROCESS_MANAGERS[0],
            &entry,
            "D",
            "x1",
            None,
            depth,
            &mut self.all_events,
            &mut self.mutations,
            &mut self.cross_domain,
            &mut self.reaction_log,
            &mut self.saga_log,
        );
    }
}

fn reaction(entry: &Json) -> (String, bool) {
    (entry.get("policy").and_then(Json::as_str).unwrap().to_string(), matches!(entry.get("delivered"), Some(Json::Bool(true))))
}

fn reason(entry: &Json) -> Option<&str> {
    entry.get("reason").and_then(Json::as_str)
}

const DEPTH_REACHED: &str = "reaction depth 5 reached";

// ---- policy matching ----

#[test]
fn a_policy_answers_only_the_event_it_names() {
    let mut w = world();

    w.react(&event("Placed", "D::Order", "o1", Json::obj(vec![])), 0);
    w.react(&event("Unrelated", "D::Order", "o1", Json::obj(vec![])), 0);

    assert_eq!(w.verbs(), ["D::Order.Notify"]);
    assert_eq!(w.reaction_log.iter().map(reaction).collect::<Vec<_>>(), [("NotifyOnPlaced".to_string(), true)]);
}

#[test]
fn a_policy_with_an_event_qualifier_fires_only_for_that_emitting_aggregate() {
    let mut w = world();

    w.react(&event("Qual", "D::Order", "o1", Json::obj(vec![])), 0);

    assert_eq!(w.verbs(), ["D::Order.Right"], "the qualifier `Other` skips, `Order` fires");
}

#[test]
fn a_policy_whose_where_clause_fails_is_skipped_and_one_that_holds_fires() {
    let mut w = world();

    w.react(&event("Guard", "D::Order", "o1", Json::obj(vec![])), 0);

    assert_eq!(w.verbs(), ["D::Order.On"]);
}

#[test]
fn where_holds_reads_the_event_payload_and_defaults_to_true_with_no_clause() {
    fn go() -> Expr {
        Expr::Lookup("go")
    }
    let yes = event("E", "D::Order", "o1", Json::obj(vec![("go", Json::Bool(true))]));
    let no = event("E", "D::Order", "o1", Json::obj(vec![("go", Json::Bool(false))]));

    assert!(where_holds(None, &no));
    assert!(where_holds(Some(go), &yes));
    assert!(!where_holds(Some(go), &no));
    assert!(!where_holds(Some(off), &yes));
}

#[test]
fn a_cross_domain_policy_is_recorded_for_the_host_never_dispatched() {
    let mut w = world();

    w.react(&event("XEvt", "D::Order", "o1", Json::obj(vec![("k", Json::int(1))])), 0);

    assert!(w.bus.calls.is_empty());
    assert!(w.reaction_log.is_empty());
    assert_eq!(w.cross_domain.len(), 1);
    let pending = &w.cross_domain[0];
    assert_eq!((pending.policy_name.as_str(), pending.event_name.as_str()), ("XPlain", "XEvt"));
    assert_eq!((pending.target_domain.as_str(), pending.target_verb.as_str()), ("Other", "Other::Do"));
    assert_eq!(pending.payload, Json::obj(vec![("k", Json::int(1))]));
}

#[test]
fn a_cross_domain_policy_honours_its_event_qualifier_and_where_clause() {
    let mut w = world();
    w.react(&event("XQual", "D::Order", "o1", Json::obj(vec![])), 0);
    assert_eq!(w.cross_domain.iter().map(|p| p.policy_name.as_str()).collect::<Vec<_>>(), ["XQualRight"]);

    let mut w = world();
    w.react(&event("XGuard", "D::Order", "o1", Json::obj(vec![])), 0);
    assert_eq!(w.cross_domain.iter().map(|p| p.policy_name.as_str()).collect::<Vec<_>>(), ["XWhereOn"]);

    let mut w = world();
    w.react(&event("Nothing", "D::Order", "o1", Json::obj(vec![])), 0);
    assert!(w.cross_domain.is_empty());
}

// ---- the depth ceiling ----

#[test]
fn a_reaction_below_the_depth_ceiling_is_delivered_and_one_at_it_is_logged_undelivered() {
    for (depth, delivers) in [(0, true), (3, true), (4, false), (5, false)] {
        let mut w = world();

        w.react(&event("Placed", "D::Order", "o1", Json::obj(vec![])), depth);

        assert_eq!(w.verbs().len(), usize::from(delivers), "depth {depth}");
        assert_eq!(w.reaction_log.iter().map(reaction).collect::<Vec<_>>(), [("NotifyOnPlaced".to_string(), delivers)], "depth {depth}");
        if !delivers {
            assert_eq!(reason(&w.reaction_log[0]), Some(DEPTH_REACHED));
        }
    }
}

#[test]
fn a_policy_that_re_triggers_itself_stops_after_five_dispatches() {
    let mut w = world();

    w.orchestrate("D::Order.Ping", 0).unwrap();

    assert_eq!(w.verbs(), ["D::Order.Ping"; 5]);
    let delivered: Vec<bool> = w.reaction_log.iter().map(|entry| reaction(entry).1).collect();
    // The innermost reaction is logged first: the ceiling, then the four that delivered.
    assert_eq!(delivered, [false, true, true, true, true]);
    assert_eq!(reason(&w.reaction_log[0]), Some(DEPTH_REACHED));
}

#[test]
fn a_fan_out_dispatches_once_per_row_with_the_row_id_under_the_declared_key_one_level_deeper() {
    let mut w = world();

    w.react(&event("Fan", "D::Order", "o1", Json::obj(vec![])), 3);

    // Each row dispatches `Ping` at depth 4, whose own `Pinger` reaction is stopped there.
    assert_eq!(w.verbs(), ["D::Order.Ping", "D::Order.Ping"]);
    assert_eq!(w.bus.calls[0].1, Json::obj(vec![("order_id", Json::str("o1"))]));
    assert_eq!(w.bus.calls[1].1, Json::obj(vec![("order_id", Json::str("o2"))]));
    let log: Vec<(String, bool)> = w.reaction_log.iter().map(reaction).collect();
    assert_eq!(log.iter().filter(|(name, _)| name == "Pinger").count(), 2);
    assert!(w.reaction_log.iter().any(|entry| entry.get("for_row").and_then(Json::as_str) == Some("o2")));
}

#[test]
fn a_fan_out_over_a_query_nothing_declares_logs_the_missing_query() {
    let mut w = world();

    w.react(&event("FanMissing", "D::Order", "o1", Json::obj(vec![])), 0);

    assert!(w.bus.calls.is_empty());
    assert_eq!(reason(&w.reaction_log[0]), Some("no query D::Order.Missing"));
}

#[test]
fn a_saga_leg_stopped_at_the_ceiling_logs_it_and_never_dispatches() {
    let mut w = world();

    assert_eq!(w.deliver_saga(4), None);

    assert!(w.bus.calls.is_empty());
    assert_eq!(reason(&w.saga_log[0]), Some(DEPTH_REACHED));
}

#[test]
fn a_saga_leg_just_under_the_ceiling_dispatches_one_level_deeper() {
    let mut w = world();

    assert_eq!(w.deliver_saga(3), Some(true));

    // Dispatched at depth 4, so the `Ping` it emits meets the ceiling and is not re-triggered.
    assert_eq!(w.verbs(), ["D::Order.Ping"]);
    assert_eq!(reason(&w.reaction_log[0]), Some(DEPTH_REACHED));
}

#[test]
fn a_derived_compensation_stopped_at_the_ceiling_is_logged_failed_and_never_dispatches() {
    let mut w = world();

    w.deliver_compensation(4);

    assert!(w.bus.calls.is_empty());
    assert_eq!(reason(&w.saga_log[0]), Some(DEPTH_REACHED));
    assert_eq!(w.saga_log[0].get("compensation_failed"), Some(&Json::Bool(true)));
}

#[test]
fn a_derived_compensation_just_under_the_ceiling_dispatches_one_level_deeper() {
    let mut w = world();

    w.deliver_compensation(3);

    assert_eq!(w.verbs(), ["D::Order.Ping"]);
    assert_eq!(reason(&w.reaction_log[0]), Some(DEPTH_REACHED));
    assert_eq!(w.saga_log[0].get("delivered"), Some(&Json::Bool(true)));
}

// ---- sagas ----

fn dispatch_log(w: &World) -> Vec<(String, bool, bool)> {
    w.saga_log
        .iter()
        .filter_map(|entry| {
            let dispatch = entry.get("dispatch")?.as_str()?.to_string();
            Some((dispatch, matches!(entry.get("delivered"), Some(Json::Bool(true))), matches!(entry.get("compensation"), Some(Json::Bool(true)))))
        })
        .collect()
}

#[test]
fn a_saga_is_born_advances_and_ends_on_its_declared_events() {
    let mut w = world();
    let key = ("Transfer".to_string(), "x1".to_string());

    w.orchestrate("D::Xfer.Started", 0).unwrap();
    assert_eq!(w.sagas[&key].state, "start");
    assert_eq!(w.saga_log[0].get("born"), Some(&Json::Bool(true)));

    w.orchestrate("D::Xfer.Funded", 0).unwrap();
    assert_eq!(w.sagas[&key].state, "mid");
    assert_eq!(w.verbs(), ["D::Xfer.Started", "D::Xfer.Funded", "D::Ship.Go"]);
    assert_eq!(w.bus.calls[2].1, Json::obj(vec![("ref", Json::str("x1"))]));
    let ledger = &w.sagas[&key].completed_compensations;
    assert_eq!(ledger.len(), 1);
    assert_eq!((ledger[0].command_name.as_str(), &ledger[0].args), ("Ship.Undo", &Json::obj(vec![("ref", Json::str("x1"))])));

    w.orchestrate("D::Xfer.Ended", 0).unwrap();
    assert!(w.sagas.is_empty());
    assert_eq!(w.saga_log.last().unwrap().get("ended"), Some(&Json::Bool(true)));
}

#[test]
fn a_leg_that_refuses_runs_the_refused_leg_and_fires_earlier_compensations() {
    let mut w = world();
    let key = ("Risky".to_string(), "x1".to_string());

    w.orchestrate("D::Xfer.RiskyStarted", 0).unwrap();
    w.orchestrate("D::Xfer.RiskyFunded", 0).unwrap();

    assert_eq!(w.verbs(), ["D::Xfer.RiskyStarted", "D::Xfer.RiskyFunded", "D::Ship.Go", "D::Ship.Refuse", "D::Ship.Undo"]);
    assert_eq!(w.sagas[&key].state, "undone");
    assert!(w.sagas[&key].completed_compensations.is_empty());
    assert_eq!(
        dispatch_log(&w),
        [("Ship.Go".to_string(), true, false), ("Ship.Refuse".to_string(), false, false), ("Ship.Undo".to_string(), true, true)]
    );
    assert!(w.saga_log.iter().any(|e| e.get("on").and_then(Json::as_str) == Some("refused") && e.get("advanced") == Some(&Json::Bool(true))));
}

#[test]
fn a_refusal_in_a_saga_with_no_refused_leg_compensates_nothing_and_logs_nothing() {
    let mut w = world();
    let key = ("Plain".to_string(), "x1".to_string());

    w.orchestrate("D::Xfer.PlainStarted", 0).unwrap();
    w.orchestrate("D::Xfer.PlainFunded", 0).unwrap();

    assert_eq!(w.verbs(), ["D::Xfer.PlainStarted", "D::Xfer.PlainFunded", "D::Ship.Refuse"]);
    assert_eq!(w.sagas[&key].state, "mid");
    assert!(!w.saga_log.iter().any(|e| e.get("on").and_then(Json::as_str) == Some("refused")), "{:?}", w.saga_log);
}

#[test]
fn a_leg_naming_an_unremembered_conversation_is_logged_not_advanced() {
    let mut w = world();

    w.orchestrate("D::Xfer.Funded", 0).unwrap();

    assert_eq!(w.verbs(), ["D::Xfer.Funded"]);
    assert_eq!(w.saga_log[0].get("advanced"), Some(&Json::Bool(false)));
    assert!(reason(&w.saga_log[0]).unwrap().contains("no conversation remembers"));
}

// ---- argument assembly ----

fn rule(target: &'static str, with_spec: &'static [(&'static str, &'static str)]) -> PolicyRule {
    PolicyRule { with_spec, ..policy("P", "E", target) }
}

fn order_event(payload: Json) -> Event {
    event("E", "D::Order", "o1", payload)
}

fn payload() -> Json {
    Json::obj(vec![("amount", Json::int(5)), ("to", Json::str("zzz"))])
}

#[test]
fn an_empty_with_forwards_the_payload_and_lifts_the_event_id_to_the_receiver_of_a_non_creating_same_aggregate_target() {
    let args = trigger_args(&rule("D::Order.Close", NO_WITH), &order_event(payload()), None, "D::Order.Close", &tables());

    // The payload's own `to` is dropped; the lifted receiver replaces it.
    assert_eq!(args, Json::obj(vec![("to", Json::str("o1")), ("with", Json::obj(vec![("amount", Json::int(5))]))]));
}

#[test]
fn an_empty_with_forwards_the_payload_verbatim_when_nothing_is_lifted() {
    let t = tables();
    // A creating target, a different aggregate, a fan-out row's own key, and a verb with no
    // aggregate each leave the payload as it came.
    for (verb, extra) in [("D::Order.Place", None), ("D::Ship.Close", None), ("Close", None)] {
        let args = trigger_args(&rule(verb, NO_WITH), &order_event(payload()), extra, verb, &t);
        assert_eq!(args, payload(), "{verb}");
    }
}

#[test]
fn a_fan_out_row_id_replaces_any_payload_field_of_the_same_name_and_is_never_lifted() {
    let with_old = Json::obj(vec![("order_id", Json::str("old")), ("amount", Json::int(5))]);

    let args = trigger_args(&rule("D::Order.Close", NO_WITH), &order_event(with_old), Some(("order_id", "row-1".to_string())), "D::Order.Close", &tables());

    assert_eq!(args, Json::obj(vec![("amount", Json::int(5)), ("order_id", Json::str("row-1"))]));
}

#[test]
fn a_payload_that_is_not_an_object_forwards_as_an_empty_object() {
    let args = trigger_args(&rule("D::Order.Place", NO_WITH), &order_event(Json::Null), None, "D::Order.Place", &tables());

    assert_eq!(args, Json::Object(vec![]));
}

fn row_record() -> Json {
    Json::obj(vec![("charged", Json::int(40)), ("amount", Json::int(99))])
}

#[test]
fn an_explicit_with_may_read_a_fan_out_rows_fields_but_the_payload_wins() {
    const READ_ROW: &[(&str, &str)] = &[("note", ":charged"), ("amount", ":amount"), ("tag", ":id")];
    let record = row_record();

    let args = trigger_args_with_row(&rule("D::Order.Place", READ_ROW), &order_event(payload()), None, Some(("r1", &record)), "D::Order.Place", &tables());

    assert_eq!(args, Json::obj(vec![("note", Json::int(40)), ("amount", Json::int(5)), ("tag", Json::str("r1"))]));
}

#[test]
fn an_undeclared_with_never_offers_a_fan_out_rows_fields() {
    let record = row_record();
    let extra = Some(("order_id", "r1".to_string()));

    let args = trigger_args_with_row(&rule("D::Order.Place", NO_WITH), &order_event(payload()), extra, Some(("r1", &record)), "D::Order.Place", &tables());

    assert_eq!(args, Json::obj(vec![("amount", Json::int(5)), ("to", Json::str("zzz")), ("order_id", Json::str("r1"))]));
}

const READS_ORDER_ID: crate::kernel::QueryDef = crate::kernel::QueryDef {
    verb: "D::Order.ForOrder",
    aggregate: "D::Order",
    conditions: &[crate::kernel::QueryCondition {
        field: "order_id",
        comparator: crate::kernel::query_comparators::QueryComparator::Eq,
        value: crate::kernel::QueryConditionValue::Arg("order_id"),
    }],
    reference_hop_conditions: &[],
    order_by: None,
    offset: None,
    limit: None,
    authorization: None,
};

#[test]
fn a_for_each_query_is_lent_the_emitting_records_id_under_its_identity_head() {
    let args = for_each_query_args(&READS_ORDER_ID, &order_event(Json::obj(vec![])), &tables());

    assert_eq!(args, Json::obj(vec![("order_id", Json::str("o1"))]));
}

#[test]
fn a_for_each_query_keeps_a_payload_value_over_the_lent_identity() {
    let args = for_each_query_args(&READS_ORDER_ID, &order_event(Json::obj(vec![("order_id", Json::str("mine"))])), &tables());

    assert_eq!(args, Json::obj(vec![("order_id", Json::str("mine"))]));
}

#[test]
fn a_for_each_query_that_does_not_read_the_head_is_lent_nothing() {
    let args = for_each_query_args(&QUERIES[0], &order_event(payload()), &tables());

    assert_eq!(args, payload());
}

#[test]
fn a_for_each_query_is_lent_nothing_for_an_aggregate_without_a_single_head() {
    let args = for_each_query_args(&READS_ORDER_ID, &event("E", "D::Other", "x1", Json::obj(vec![])), &tables());

    assert_eq!(args, Json::obj(vec![]));
}

const PROJECT: &[(&str, &str)] = &[("amount", ":amount"), ("note", "\"hi\""), ("tag", ":absent")];

#[test]
fn an_explicit_with_projects_source_fields_decodes_literals_and_nulls_what_is_absent() {
    let args = trigger_args(&rule("D::Order.Place", PROJECT), &order_event(payload()), None, "D::Order.Place", &tables());

    assert_eq!(args, Json::obj(vec![("amount", Json::int(5)), ("note", Json::str("hi")), ("tag", Json::Null)]));
}

#[test]
fn an_explicit_with_may_read_the_emitting_records_identity_unless_the_payload_carries_it() {
    const READ_ID: &[(&str, &str)] = &[("order_id", ":order_id")];
    let t = tables();

    let from_event = trigger_args(&rule("D::Order.Place", READ_ID), &order_event(payload()), None, "D::Order.Place", &t);
    assert_eq!(from_event, Json::obj(vec![("order_id", Json::str("o1"))]));

    let carried = Json::obj(vec![("order_id", Json::str("p9"))]);
    let from_payload = trigger_args(&rule("D::Order.Place", READ_ID), &order_event(carried), None, "D::Order.Place", &t);
    assert_eq!(from_payload, Json::obj(vec![("order_id", Json::str("p9"))]));

    let blank = event("E", "D::Order", "", payload());
    let none = trigger_args(&rule("D::Order.Place", READ_ID), &blank, None, "D::Order.Place", &t);
    assert_eq!(none, Json::obj(vec![("order_id", Json::Null)]));
}

#[test]
fn an_explicit_with_for_a_non_creating_target_names_the_receiver_from_the_projection_or_the_event() {
    const REASON: &[(&str, &str)] = &[("reason", "\"x\"")];
    const BOTH: &[(&str, &str)] = &[("order_id", ":order_id"), ("reason", "\"x\"")];
    let t = tables();

    // Nothing projected names the identity: the same-aggregate event's own id is the receiver.
    let fallback = trigger_args(&rule("D::Order.Close", REASON), &order_event(payload()), None, "D::Order.Close", &t);
    assert_eq!(fallback, Json::obj(vec![("to", Json::str("o1")), ("with", Json::obj(vec![("reason", Json::str("x"))]))]));

    // The projection names it: that wins and is not re-routed.
    let named = trigger_args(&rule("D::Order.Close", BOTH), &order_event(payload()), None, "D::Order.Close", &t);
    assert_eq!(
        named,
        Json::obj(vec![("to", Json::str("o1")), ("with", Json::obj(vec![("order_id", Json::str("o1")), ("reason", Json::str("x"))]))])
    );

    // A different aggregate has no event identity to offer, and a fan-out row never falls back.
    let other = trigger_args(&rule("D::Ship.Close", REASON), &order_event(payload()), None, "D::Ship.Close", &t);
    assert_eq!(other, Json::obj(vec![("reason", Json::str("x"))]));
    let fan = trigger_args(&rule("D::Order.Close", REASON), &order_event(payload()), Some(("order_id", "r1".to_string())), "D::Order.Close", &t);
    assert_eq!(fan, Json::obj(vec![("reason", Json::str("x"))]));
}

// A fact that happens to be called `to` or `with` is not an already-routed envelope: only an
// object carrying both keys is, so a lone one is still wrapped under the event's receiver.
#[test]
fn a_projected_fact_named_to_or_with_alone_is_not_mistaken_for_an_already_routed_envelope() {
    const JUST_TO: &[(&str, &str)] = &[("to", "\"somewhere\"")];
    const JUST_WITH: &[(&str, &str)] = &[("with", "\"w\"")];
    let t = tables();

    let to = trigger_args(&rule("D::Order.Close", JUST_TO), &order_event(payload()), None, "D::Order.Close", &t);
    assert_eq!(to, Json::obj(vec![("to", Json::str("o1")), ("with", Json::obj(vec![("to", Json::str("somewhere"))]))]));

    let with = trigger_args(&rule("D::Order.Close", JUST_WITH), &order_event(payload()), None, "D::Order.Close", &t);
    assert_eq!(with, Json::obj(vec![("to", Json::str("o1")), ("with", Json::obj(vec![("with", Json::str("w"))]))]));
}

#[test]
fn an_entity_command_is_routed_to_the_parent_named_by_the_event_when_the_projection_does_not_name_it() {
    let t = tables();
    let projected = || Json::obj(vec![("line_id", Json::str("l1")), ("note", Json::str("n"))]);

    let got = route_dispatch_args(projected(), "D::Order.Line.Add", &t, &order_event(payload()));
    assert_eq!(
        got,
        Json::obj(vec![
            ("to", Json::obj(vec![("aggregate", Json::str("o1")), ("entities", Json::Array(vec![Json::str("l1")]))])),
            ("with", projected()),
        ])
    );

    // Another aggregate's event identifies nothing, and neither does a blank id.
    let other = event("E", "D::Other", "o1", payload());
    let blank = event("E", "D::Order", "", payload());
    for e in [other, blank] {
        let flat = route_dispatch_args(projected(), "D::Order.Line.Add", &t, &e);
        assert!(flat.get("to").is_none(), "{flat:?}");
    }
}

#[test]
fn resolve_with_reads_the_correlation_then_the_payload_then_the_memory_then_null() {
    let pm = &PROCESS_MANAGERS[0];
    let e = event("E", "D::Xfer", "x1", Json::obj(vec![("from_event", Json::str("p"))]));
    let memory = Json::obj(vec![("from_memory", Json::str("m"))]);
    let resolve = |name: &'static str| resolve_with(pm, &WithValue::Ref(name), &e, "corr", &memory);

    assert_eq!(resolve("ref"), Json::str("corr"));
    assert_eq!(resolve("from_event"), Json::str("p"));
    assert_eq!(resolve("from_memory"), Json::str("m"));
    assert_eq!(resolve("nowhere"), Json::Null);
}

#[test]
fn read_literal_wire_treats_a_lone_or_half_quoted_word_as_bare() {
    assert_eq!(read_literal_wire("\""), Json::str("\""));
    assert_eq!(read_literal_wire("abc\""), Json::str("abc\""));
    assert_eq!(read_literal_wire("\"abc"), Json::str("\"abc"));
    assert_eq!(read_literal_wire("\"\""), Json::str(""));
}
