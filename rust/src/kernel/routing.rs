// HAND-WRITTEN, DOMAIN-AGNOSTIC invocation boundary. Receiver identity is
// transport/routing data; command facts are a different channel. Generated
// routers accept this shape while retaining the legacy mixed-args object as a
// compatibility input during migration.

use super::{Json, Refusal};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RoutingEnvelope {
    aggregate: String,
    entities: Vec<String>,
}

impl RoutingEnvelope {
    pub fn from_json(value: &Json) -> Result<Self, Refusal> {
        match value {
            Json::Str(aggregate) => Ok(Self {
                aggregate: nonempty_identity(aggregate, "to")?,
                entities: Vec::new(),
            }),
            Json::Object(_) => {
                let aggregate = value
                    .get("aggregate")
                    .and_then(Json::as_str)
                    .ok_or_else(|| {
                        routing_refusal("entity route requires a scalar aggregate identity")
                    })?;
                let aggregate = nonempty_identity(aggregate, "to.aggregate")?;

                let entity = value.get("entity");
                let entities = value.get("entities");
                let entities = match (entity, entities) {
                    (Some(_), Some(_)) => {
                        return Err(routing_refusal(
                            "entity route accepts either entity or entities, not both",
                        ));
                    }
                    (Some(Json::Str(identity)), None) => {
                        vec![nonempty_identity(identity, "to.entity")?]
                    }
                    (Some(_), None) => {
                        return Err(routing_refusal("to.entity must be a scalar identity"))
                    }
                    (None, Some(Json::Array(identities))) => {
                        if identities.is_empty() {
                            return Err(routing_refusal(
                                "entity route requires at least one entity identity",
                            ));
                        }
                        identities
                            .iter()
                            .enumerate()
                            .map(|(index, identity)| {
                                let identity = identity.as_str().ok_or_else(|| {
                                    routing_refusal(&format!(
                                        "to.entities[{index}] must be a scalar identity"
                                    ))
                                })?;
                                nonempty_identity(identity, &format!("to.entities[{index}]"))
                            })
                            .collect::<Result<Vec<_>, _>>()?
                    }
                    (None, Some(_)) => {
                        return Err(routing_refusal(
                            "to.entities must be an ordered identity list",
                        ))
                    }
                    (None, None) => {
                        return Err(routing_refusal(
                            "entity route requires at least one entity identity",
                        ))
                    }
                };

                Ok(Self {
                    aggregate,
                    entities,
                })
            }
            _ => Err(routing_refusal(
                "to must be an aggregate identity or an entity route",
            )),
        }
    }

    pub fn aggregate(&self) -> &str {
        &self.aggregate
    }

    pub fn entities(&self) -> &[String] {
        &self.entities
    }

    pub fn require_depth(&self, expected: usize) -> Result<(), Refusal> {
        if self.entities.len() == expected {
            Ok(())
        } else {
            Err(routing_refusal(&format!(
                "route requires {expected} entity identit{}, got {}",
                if expected == 1 { "y" } else { "ies" },
                self.entities.len()
            )))
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct CommandInvocation {
    route: Option<RoutingEnvelope>,
    facts: Json,
}

impl CommandInvocation {
    /// Parses either an explicit `{ "to": ..., "with": {...} }` routed
    /// invocation, an unrouted create `{ "with": {...} }`, or a legacy
    /// mixed command-args object. `to` or `with` selects the explicit form
    /// — but only when PRESENT AND NON-NULL. BUG#16: a legacy-shaped
    /// payload whose own domain declares a fact literally named `to`
    /// (`Roster::Roster.Notice`, `optional: true`, no `sets` — deliberately
    /// the same naming collision BUG#7's own comment on `scalar_envelope`
    /// already documents for `Mark`) still carries a `"to"` key when that
    /// fact is offered as JSON `null` — the fuzzer's ordinary way of
    /// spelling "argument omitted" for an optional field, and exactly what
    /// `Fuzzing::Replay`/`StepBuilder` produce. `value.get("to")` answers
    /// `Some(Json::Null)`, not `None`, for that key — so the OLD `target.
    /// is_none()` check read a present-but-null `to` as "the caller wants
    /// explicit routing," and `RoutingEnvelope::from_json(&Json::Null)`
    /// then refused it, TypeMismatch, before the domain's own generated
    /// `NoticeArgs::from_json` (which already treats `Some(Json::Null)`
    /// the same as absence, correctly) ever got a chance to accept it —
    /// Ruby's own `Dispatcher#dispatch(verb, to: nil, with: nil, **legacy)`
    /// takes the identical `to: nil` through `Routing.envelope`, which
    /// short-circuits (`return nil if to.nil?`) without ever attempting to
    /// parse a route from it, so Ruby succeeds where Rust refused —
    /// confirmed live, `bin/qa_sweep roster --seeds 4`. `non_null` restores
    /// that same "JSON null reads as absent" contract on this side, for
    /// `to` and `with` alike (the two are otherwise symmetric here).
    ///
    /// `strip_null_routing_keys` — the SAME fix's other half. Ruby's own
    /// `dispatch(verb, to: nil, with: nil, ..., **legacy_args)` captures a
    /// top-level `to`/`with` key into ITS OWN keyword parameters
    /// UNCONDITIONALLY — `legacy_args` (what actually reaches the domain,
    /// and what an emitted event's payload is built from) never carries
    /// either key at all once that kwarg binding has run, whether the
    /// caller offered `nil` or omitted the key entirely; Ruby cannot even
    /// tell the two apart. Left as `value.clone()` unstripped, Rust's own
    /// legacy-shape facts still carried the literal `"to": null` entry
    /// through to `MarkNoticed`'s own emitted payload (`Json::overlay`,
    /// the generated dispatch code's own `payload` local) even once the
    /// parse-level TypeMismatch above was fixed — an event-payload
    /// content divergence, confirmed live the same way.
    pub fn from_json(value: &Json) -> Result<Self, Refusal> {
        let target = non_null(value.get("to"));
        let explicit_facts = non_null(value.get("with"));
        if target.is_none() && explicit_facts.is_none() {
            return Ok(Self {
                route: None,
                facts: strip_null_routing_keys(value),
            });
        }

        if value.get("args").is_some() {
            return Err(routing_refusal("cannot combine to/with with legacy args"));
        }

        // BUG#18's own `with:` half. `with:` chooses the EXPLICIT
        // envelope — Ruby's own `Routing.payload` doc comment: "a caller
        // choosing the explicit envelope cannot smuggle receiver
        // identity back into the payload" — so a `with:` key sitting
        // beside a genuine LEGACY FACT (the mixed-args convention the
        // fuzzer's own nested `step["args"]` object otherwise carries
        // wholesale, `command_input`'s own doc comment above — a domain
        // fact happening to collide with the reserved name `with`,
        // exactly the class BUG#7/#16 already fixed for `to`) is the
        // same conflict Ruby's own `with && !legacy.empty?` check
        // already refuses, TypeMismatch, before ever looking at what
        // `with:` actually contains. Unchecked here, that sibling key
        // was simply DISCARDED (facts became `with:`'s own value,
        // whole) and whatever `with:` held next got judged on ITS OWN
        // merits — an out-of-contract routing-shaped object landed as
        // ordinary command facts and only then refused UnknownArgument,
        // a different KIND for the identical malformed step.
        //
        // NOT every sibling key is a legacy fact, though — `command_
        // input`'s own comment above documents TWO real wire shapes
        // sharing this one parser: a "direct caller" whose STEP ITSELF
        // carries top-level `to`/`with` beside `verb`/`role`/
        // `actor_id`/`occurred_at`/`dry_run`/`query` (this kernel's own
        // envelope, read directly off `step` — `top_level_with_selects_
        // an_unrouted_compound_create_invocation`, below, pins this),
        // and the fuzzer's own nested-`args` shape, where NONE of those
        // step-level names ever appear (they live one level up, outside
        // whatever object this function ever sees) — so a real domain
        // fact and a step-envelope key are told apart by name here, the
        // same way `args` already is (the check just above this one).
        // A domain that names an actual FACT `role`/`verb`/etc. is the
        // same open, pre-existing collision class `to`/`with` already
        // are — not this bug's concern to close for every reserved name
        // at once.
        const STEP_ENVELOPE_KEYS: [&str; 6] =
            ["verb", "role", "actor_id", "occurred_at", "dry_run", "query"];
        if explicit_facts.is_some() {
            if let Json::Object(fields) = value {
                let extra = fields
                    .iter()
                    .any(|(key, _)| key != "to" && key != "with" && !STEP_ENVELOPE_KEYS.contains(&key.as_str()));
                if extra {
                    return Err(routing_refusal(
                        "with: takes command facts, not both with: and loose keyword arguments",
                    ));
                }
            }
        }

        let route = target.map(RoutingEnvelope::from_json).transpose()?;
        let facts = explicit_facts
            .cloned()
            .unwrap_or_else(|| Json::Object(Vec::new()));
        if !matches!(facts, Json::Object(_)) {
            return Err(routing_refusal("with must be an object of command facts"));
        }

        Ok(Self { route, facts })
    }

    pub fn route(&self) -> Option<&RoutingEnvelope> {
        self.route.as_ref()
    }

    pub fn facts(&self) -> &Json {
        &self.facts
    }

    /// Splits an aggregate-scoped port invocation into receiver identity and
    /// external facts. A migration-era operation may name its old self-
    /// reference field; that field is accepted as a legacy receiver source
    /// but is removed from the returned facts in both invocation forms.
    /// `to_receiver_field` — the `to:`-declared operation counterpart to
    /// `legacy_receiver_field` (Dispatcher#port_invocation's own second,
    /// additive branch, lib/hecks/runtime/dispatcher.rb). A genuinely
    /// separate parameter, not folded into `legacy_receiver_field`, for
    /// exactly one reason: a legacy receiver is synthetic routing-only
    /// state and gets stripped from the returned facts below; a `to:`
    /// receiver is a REAL declared external fact (rust/parser's own
    /// domain_port.rs header: "declare only external facts with
    /// attribute") that the operation's own generated Args struct still
    /// expects to find in its payload — stripping it the same way would
    /// reproduce the exact AbsentArgument bug the Ruby side hit first
    /// (dispatcher.rb's own comment on why `[]` replaced `delete` there).
    pub fn split_aggregate_receiver(
        &self,
        legacy_receiver_field: Option<&str>,
        to_receiver_field: Option<&str>,
    ) -> Result<(String, Json), Refusal> {
        let receiver = if let Some(route) = self.route() {
            route.require_depth(0)?;
            route.aggregate().to_string()
        } else if let Some(field) = legacy_receiver_field {
            self.facts
                .get(field)
                .ok_or_else(|| routing_refusal("aggregate-scoped operation requires to"))?
                .to_id_component()?
        } else if let Some(field) = to_receiver_field {
            self.facts
                .get(field)
                .ok_or_else(|| routing_refusal("aggregate-scoped operation requires to"))?
                .to_id_component()?
        } else {
            return Err(routing_refusal("aggregate-scoped operation requires to"));
        };

        // ONLY THE LEGACY FIELD IS STRIPPED — to_receiver_field stays in
        // the returned facts (see this method's own header comment).
        let facts = match (&self.facts, legacy_receiver_field) {
            (Json::Object(fields), Some(field)) => Json::Object(
                fields
                    .iter()
                    .filter(|(name, _)| name != field)
                    .cloned()
                    .collect(),
            ),
            _ => self.facts.clone(),
        };
        Ok((receiver, facts))
    }
}

// BUG#16 — `value.get("to")`/`.get("with")` answer `Some(&Json::Null)` for
// a key that is PRESENT with a JSON `null` value, not `None` — the two are
// different questions (does the key exist vs. does it carry a value), and
// `CommandInvocation::from_json`'s own "is this the explicit routed form"
// test only ever meant the second one. Filters a null value back down to
// `None`, matching Ruby's `to.nil?`/`with.nil?` (`Routing.envelope`,
// `Routing.payload`), which never distinguishes "omitted" from "offered
// as null" either.
fn non_null(value: Option<&Json>) -> Option<&Json> {
    value.filter(|v| !matches!(v, Json::Null))
}

// The other half of BUG#16's fix — see `from_json`'s own doc comment.
// Only ever called once `from_json` has already decided a payload is
// legacy-shaped (no `to`/`with` present-and-non-null), so this only ever
// drops a `to`/`with` key that carried an explicit JSON `null` — a
// present-but-empty key, matching what Ruby's own `to:`/`with:` keyword
// capture ALSO discards unconditionally before a domain ever sees it.
// Never touches a non-null `to`/`with` (that shape never reaches this
// function: `from_json` takes the OTHER branch for it), so a domain
// legitimately declaring its own non-optional fact under either name —
// `Roster::Roster.Mark`'s own `to`, offered as a real value — is
// unaffected; BUG#7's own established, matching-refusal behavior for
// that collision stays exactly as it was.
fn strip_null_routing_keys(value: &Json) -> Json {
    match value {
        Json::Object(fields) => Json::Object(
            fields
                .iter()
                .filter(|(name, v)| !((name == "to" || name == "with") && matches!(v, Json::Null)))
                .cloned()
                .collect(),
        ),
        other => other.clone(),
    }
}

fn nonempty_identity(value: &str, location: &str) -> Result<String, Refusal> {
    if value.is_empty() {
        Err(routing_refusal(&format!(
            "{location} identity must not be empty"
        )))
    } else {
        Ok(value.to_string())
    }
}

fn routing_refusal(message: &str) -> Refusal {
    Refusal::TypeMismatch(format!("invalid routing envelope: {message}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn separates_aggregate_receiver_from_command_facts() {
        let input = Json::obj(vec![
            ("to", Json::str("DOWNTOWN:12")),
            ("with", Json::obj(vec![("amount", Json::int(20))])),
        ]);

        let invocation = CommandInvocation::from_json(&input).unwrap();
        let route = invocation.route().unwrap();
        route.require_depth(0).unwrap();
        assert_eq!(route.aggregate(), "DOWNTOWN:12");
        assert_eq!(
            invocation.facts(),
            &Json::obj(vec![("amount", Json::int(20))])
        );
        assert_eq!(invocation.facts().get("to"), None);
    }

    #[test]
    fn preserves_ordered_entity_receiver_identities() {
        let input = Json::obj(vec![
            (
                "to",
                Json::obj(vec![
                    ("aggregate", Json::str("DOWNTOWN:12")),
                    (
                        "entities",
                        Json::Array(vec![Json::str("2026-01-05:1"), Json::str("note:7")]),
                    ),
                ]),
            ),
            ("with", Json::obj(vec![("note", Json::str("Flagged"))])),
        ]);

        let invocation = CommandInvocation::from_json(&input).unwrap();
        let route = invocation.route().unwrap();
        route.require_depth(2).unwrap();
        assert_eq!(route.aggregate(), "DOWNTOWN:12");
        assert_eq!(route.entities(), &["2026-01-05:1", "note:7"]);
        assert_eq!(
            invocation.facts(),
            &Json::obj(vec![("note", Json::str("Flagged"))])
        );
    }

    #[test]
    fn admits_the_one_entity_shorthand_and_legacy_args() {
        let routed = Json::obj(vec![(
            "to",
            Json::obj(vec![
                ("aggregate", Json::str("DOWNTOWN:12")),
                ("entity", Json::str("2026-01-05:1")),
            ]),
        )]);
        let route = CommandInvocation::from_json(&routed)
            .unwrap()
            .route()
            .unwrap()
            .clone();
        assert_eq!(route.entities(), &["2026-01-05:1"]);

        let legacy = Json::obj(vec![
            ("number", Json::str("A-1")),
            ("amount", Json::int(20)),
        ]);
        let invocation = CommandInvocation::from_json(&legacy).unwrap();
        assert_eq!(invocation.route(), None);
        assert_eq!(invocation.facts(), &legacy);
    }

    #[test]
    fn compound_create_keeps_identity_members_in_explicit_facts_without_a_route() {
        let input = Json::obj(vec![(
            "with",
            Json::obj(vec![
                ("branch_code", Json::str("DOWNTOWN")),
                ("box_number", Json::int(12)),
                ("size", Json::str("large")),
            ]),
        )]);

        let invocation = CommandInvocation::from_json(&input).unwrap();
        assert_eq!(invocation.route(), None);
        assert_eq!(
            invocation.facts(),
            &Json::obj(vec![
                ("branch_code", Json::str("DOWNTOWN")),
                ("box_number", Json::int(12)),
                ("size", Json::str("large")),
            ])
        );
    }

    // BUG#16 — a legacy-shaped payload whose domain declares its own
    // fact literally named `to` (`Roster::Roster.Notice`, `optional:
    // true`) offered as explicit JSON null (the fuzzer's own way of
    // spelling "omitted" for an optional argument — see this method's
    // own header comment) used to be misread as an attempted explicit
    // routing envelope, and refused parsing `null` as a route —
    // TypeMismatch — before the domain's own generated args parser ever
    // saw it. `to: null` (no `with` key at all) must fall through to the
    // legacy mixed-args form, exactly like `to` being absent entirely.
    // Also: the stray `"to": null` key must not survive into `facts` —
    // Ruby's own `to:` keyword capture drops it unconditionally, and an
    // emitted event's payload is built from these same facts
    // (`Json::overlay`, the generated dispatch code), so a leftover null
    // key here would still show up as a payload-content divergence even
    // once the routing misparse itself is fixed.
    #[test]
    fn null_to_with_no_with_key_is_read_as_legacy_shape_not_a_route() {
        let input = Json::obj(vec![
            ("to", Json::Null),
            ("name", Json::obj(vec![("value", Json::str("golf"))])),
        ]);

        let invocation = CommandInvocation::from_json(&input).unwrap();
        assert_eq!(invocation.route(), None);
        assert_eq!(
            invocation.facts(),
            &Json::obj(vec![("name", Json::obj(vec![("value", Json::str("golf"))]))])
        );
    }

    // Same asymmetry, the `with` side — offered as explicit null with no
    // `to` key, it must fall through to the legacy shape too, not be
    // read as "explicit facts of null," and the stray null key must not
    // survive into `facts` either.
    #[test]
    fn null_with_and_no_to_key_is_read_as_legacy_shape_not_explicit_facts() {
        let input = Json::obj(vec![
            ("with", Json::Null),
            ("amount", Json::int(20)),
        ]);

        let invocation = CommandInvocation::from_json(&input).unwrap();
        assert_eq!(invocation.route(), None);
        assert_eq!(invocation.facts(), &Json::obj(vec![("amount", Json::int(20))]));
    }

    // A domain fact legitimately named `to`, offered NON-null in the
    // legacy shape, is UNCHANGED by this fix — it never reaches
    // `strip_null_routing_keys` at all (`from_json` takes the routed-
    // envelope branch for it instead), so `Roster::Roster.Mark`'s own
    // required `to` collides with routing exactly as it always did
    // (BUG#7's own established, matching-refusal behavior).
    #[test]
    fn non_null_to_still_takes_the_routing_branch_not_the_legacy_one() {
        let input = Json::obj(vec![("to", Json::obj(vec![("value", Json::int(282))]))]);

        let err = CommandInvocation::from_json(&input).unwrap_err();
        assert!(err.to_string().contains("entity route requires a scalar aggregate identity"));
    }

    #[test]
    fn refuses_an_incomplete_entity_route() {
        let refusal =
            RoutingEnvelope::from_json(&Json::obj(vec![("aggregate", Json::str("DOWNTOWN:12"))]))
                .unwrap_err();
        assert!(refusal
            .to_string()
            .contains("requires at least one entity identity"));
    }

    #[test]
    fn aggregate_port_receiver_is_separate_from_explicit_and_legacy_facts() {
        let explicit = CommandInvocation::from_json(&Json::obj(vec![
            ("to", Json::str("ORDER-7")),
            (
                "with",
                Json::obj(vec![
                    ("amount", Json::int(20)),
                    ("order", Json::str("LEAK")),
                ]),
            ),
        ]))
        .unwrap();
        let (receiver, facts) = explicit.split_aggregate_receiver(Some("order"), None).unwrap();
        assert_eq!(receiver, "ORDER-7");
        assert_eq!(facts, Json::obj(vec![("amount", Json::int(20))]));

        let legacy = CommandInvocation::from_json(&Json::obj(vec![
            ("order", Json::str("ORDER-8")),
            ("amount", Json::int(30)),
        ]))
        .unwrap();
        let (receiver, facts) = legacy.split_aggregate_receiver(Some("order"), None).unwrap();
        assert_eq!(receiver, "ORDER-8");
        assert_eq!(facts, Json::obj(vec![("amount", Json::int(30))]));

        let unrouted =
            CommandInvocation::from_json(&Json::obj(vec![("amount", Json::int(40))])).unwrap();
        assert!(unrouted
            .split_aggregate_receiver(None, None)
            .unwrap_err()
            .to_string()
            .contains("requires to"));
    }

    // `to:`-DECLARED OPERATIONS — the second, additive receiver field
    // (domain_generator.rs's own comment on why it stays separate from
    // legacy_receiver_field). The one behavioral difference that matters:
    // unlike the legacy field just above, this one is a REAL declared
    // fact and must survive in `facts`, not get stripped out — a real,
    // live AbsentArgument on the Ruby side (dispatcher.rb's own comment)
    // is exactly the bug this test exists to catch on the Rust side too.
    #[test]
    fn to_declared_receiver_is_found_but_not_stripped_from_facts() {
        let invocation = CommandInvocation::from_json(&Json::obj(vec![
            ("reference", Json::str("pay1")),
            ("transaction_id", Json::str("txn_1")),
        ]))
        .unwrap();
        let (receiver, facts) = invocation
            .split_aggregate_receiver(None, Some("reference"))
            .unwrap();
        assert_eq!(receiver, "pay1");
        assert_eq!(
            facts,
            Json::obj(vec![
                ("reference", Json::str("pay1")),
                ("transaction_id", Json::str("txn_1")),
            ])
        );

        // An explicit `to:` still wins over either receiver field —
        // unchanged precedence, same as the legacy field already has.
        let explicit = CommandInvocation::from_json(&Json::obj(vec![
            ("to", Json::str("pay2")),
            ("with", Json::obj(vec![("reference", Json::str("pay1"))])),
        ]))
        .unwrap();
        let (receiver, _) = explicit
            .split_aggregate_receiver(None, Some("reference"))
            .unwrap();
        assert_eq!(receiver, "pay2");
    }

    // BUG#18 — `entities: []` (present, explicitly empty — as distinct
    // from `refuses_an_incomplete_entity_route`, above, which covers
    // `entity`/`entities` absent altogether) must refuse exactly like
    // absence does: Rust already did, unconditionally, regardless of
    // the calling command's own entity depth; this pins that this stays
    // true now that Ruby's `parse_envelope_hash` refuses it too.
    #[test]
    fn refuses_an_explicitly_empty_entities_array() {
        let refusal = RoutingEnvelope::from_json(&Json::obj(vec![
            ("aggregate", Json::str("DOWNTOWN:12")),
            ("entities", Json::Array(Vec::new())),
        ]))
        .unwrap_err();
        assert!(refusal
            .to_string()
            .contains("requires at least one entity identity"));
    }

    // BUG#18's own `with:` half — a `with:` key carrying ANY value
    // (a route-shaped object among them) beside a genuine sibling
    // command fact is the same "explicit envelope smuggling a payload
    // fact" conflict Ruby's `Routing.payload` already refuses,
    // TypeMismatch, before ever looking at what `with:` holds. This
    // used to reach the domain's own generated args parser instead
    // (`with:`'s value became `facts` whole, the sibling fact silently
    // dropped), which then refused UnknownArgument for an entirely
    // different reason — a different KIND for the identical malformed
    // step. Now both refuse at the same point, for the same reason.
    #[test]
    fn refuses_with_beside_a_sibling_legacy_fact_the_same_as_ruby_does() {
        let input = Json::obj(vec![
            (
                "with",
                Json::obj(vec![
                    ("aggregate", Json::str("F1")),
                    ("entities", Json::Array(Vec::new())),
                ]),
            ),
            ("amount", Json::int(-1)),
        ]);

        let err = CommandInvocation::from_json(&input).unwrap_err();
        assert!(err
            .to_string()
            .contains("with: takes command facts, not both with: and loose keyword arguments"));
    }

    // The step-envelope keys a "direct caller" step legitimately carries
    // beside a top-level `with:` (`command_input`'s own doc comment,
    // cli.rs) are NOT legacy facts and must not trip the check above —
    // `top_level_with_selects_an_unrouted_compound_create_invocation`
    // (kernel::cli::routing_tests) already pins `verb`; this covers the
    // rest of that same set directly against `CommandInvocation` itself.
    #[test]
    fn step_envelope_keys_beside_with_are_not_mistaken_for_legacy_facts() {
        let input = Json::obj(vec![
            ("verb", Json::str("Banking::SafeDepositBox.Rent")),
            ("role", Json::str("Teller")),
            ("actor_id", Json::str("u1")),
            ("occurred_at", Json::str("2026-01-05T00:00:00Z")),
            (
                "with",
                Json::obj(vec![("branch_code", Json::str("DOWNTOWN"))]),
            ),
        ]);

        let invocation = CommandInvocation::from_json(&input).unwrap();
        assert_eq!(invocation.route(), None);
        assert_eq!(
            invocation.facts(),
            &Json::obj(vec![("branch_code", Json::str("DOWNTOWN"))])
        );
    }
}
