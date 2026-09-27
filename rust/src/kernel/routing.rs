// Domain-agnostic invocation boundary: receiver identity (routing) is separate from command facts.

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

    // Wording matches Ruby's `Invocation.route` so refusals byte-compare across both sides.
    pub fn require_depth(&self, expected: usize) -> Result<(), Refusal> {
        if self.entities.len() == expected {
            Ok(())
        } else {
            Err(Refusal::TypeMismatch(format!(
                "to: for an entity command needs {expected} entity identit{} after the aggregate — got {}",
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
    // True for the explicit `with:` shape, false for flat facts. Ruby validates `with:` facts
    // before checking route depth but not flat facts, so an aggregate command needs the shape
    // to refuse in the same order.
    explicit: bool,
}

impl CommandInvocation {
    /// Parses an explicit `{ "to": ..., "with": {...} }` invocation, an unrouted create
    /// `{ "with": {...} }`, or a flat mixed-args object.
    ///
    /// JSON `null` for `to` or `with` reads as absent, and `to`/`with` never reach the facts
    /// of the flat shape; Ruby binds them as keyword arguments and cannot tell the cases apart.
    /// The facts source depends on `with:` alone, never on `to:`.
    pub fn from_json(value: &Json) -> Result<Self, Refusal> {
        let target = non_null(value.get("to"));
        let explicit_facts = non_null(value.get("with"));
        if explicit_facts.is_none() {
            let route = target.map(RoutingEnvelope::from_json).transpose()?;
            return Ok(Self {
                route,
                facts: strip_routing_keys(value),
                explicit: false,
            });
        }

        if value.get("args").is_some() {
            return Err(routing_refusal("cannot combine to/with with legacy args"));
        }

        // `with:` beside a loose fact is refused, as Ruby's `Routing.payload` refuses it.
        // Step-envelope keys (`verb`, `role`, ...) are not facts and are exempt.
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
            .expect("explicit_facts checked Some above");
        if !matches!(facts, Json::Object(_)) {
            return Err(routing_refusal("with must be an object of command facts"));
        }

        Ok(Self { route, facts, explicit: true })
    }

    pub fn route(&self) -> Option<&RoutingEnvelope> {
        self.route.as_ref()
    }

    pub fn facts(&self) -> &Json {
        &self.facts
    }

    /// True when this call used the explicit `with:` shape, false for flat facts.
    pub fn explicit_with(&self) -> bool {
        self.explicit
    }

    /// Splits an aggregate-scoped port invocation into receiver identity and external facts.
    ///
    /// `legacy_receiver_field` is routing-only and is stripped from the facts; the `to:`-declared
    /// `to_receiver_field` is a real fact the operation's Args still expects, so it is kept.
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

// JSON `null` reads as absent, matching Ruby's `to.nil?` / `with.nil?`.
fn non_null(value: Option<&Json>) -> Option<&Json> {
    value.filter(|v| !matches!(v, Json::Null))
}

// Drops `to`/`with` from flat facts unconditionally, as Ruby's keyword binding does.
fn strip_routing_keys(value: &Json) -> Json {
    match value {
        Json::Object(fields) => Json::Object(
            fields
                .iter()
                .filter(|(name, _)| name != "to" && name != "with")
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

    // A JSON-null `to` is not a route, and the stray key must not reach the event payload.
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

    // Same for a null `with`: read as the no-`to:` shape; the null key is dropped from the facts.
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

    // A non-null `to` is always parsed as a route, even when a domain fact is named `to`.
    #[test]
    fn non_null_to_still_takes_the_routing_branch_not_the_legacy_one() {
        let input = Json::obj(vec![("to", Json::obj(vec![("value", Json::int(282))]))]);

        let err = CommandInvocation::from_json(&input).unwrap_err();
        assert!(err.to_string().contains("entity route requires a scalar aggregate identity"));
    }

    // A real `to:` with flat facts and no `with:` must keep the facts; only `with:` selects them.
    #[test]
    fn non_null_scalar_to_with_no_with_key_keeps_the_flat_facts() {
        let input = Json::obj(vec![
            ("to", Json::str("ORDER-7")),
            ("quantity", Json::int(3)),
        ]);

        let invocation = CommandInvocation::from_json(&input).unwrap();
        let route = invocation.route().unwrap();
        route.require_depth(0).unwrap();
        assert_eq!(route.aggregate(), "ORDER-7");
        assert_eq!(invocation.facts(), &Json::obj(vec![("quantity", Json::int(3))]));
    }

    // Same, with an entity route as `to:`.
    #[test]
    fn non_null_entity_route_to_with_no_with_key_keeps_the_flat_facts() {
        let input = Json::obj(vec![
            (
                "to",
                Json::obj(vec![
                    ("aggregate", Json::str("DOWNTOWN:12")),
                    ("entity", Json::str("2026-01-05:1")),
                ]),
            ),
            ("note", Json::str("Flagged")),
        ]);

        let invocation = CommandInvocation::from_json(&input).unwrap();
        let route = invocation.route().unwrap();
        route.require_depth(1).unwrap();
        assert_eq!(route.aggregate(), "DOWNTOWN:12");
        assert_eq!(route.entities(), &["2026-01-05:1"]);
        assert_eq!(
            invocation.facts(),
            &Json::obj(vec![("note", Json::str("Flagged"))])
        );
    }

    // Same, with `to: null` beside real facts.
    #[test]
    fn null_to_alongside_real_facts_keeps_the_flat_facts() {
        let input = Json::obj(vec![
            ("to", Json::Null),
            ("quantity", Json::int(3)),
        ]);

        let invocation = CommandInvocation::from_json(&input).unwrap();
        assert_eq!(invocation.route(), None);
        assert_eq!(invocation.facts(), &Json::obj(vec![("quantity", Json::int(3))]));
    }

    // `explicit_with()` is true only when the explicit `with:` branch was taken.
    #[test]
    fn explicit_with_is_true_only_for_the_explicit_with_shape() {
        let with_and_to = CommandInvocation::from_json(&Json::obj(vec![
            ("to", Json::str("DOWNTOWN:12")),
            ("with", Json::obj(vec![("amount", Json::int(20))])),
        ]))
        .unwrap();
        assert!(with_and_to.explicit_with());

        let with_only = CommandInvocation::from_json(&Json::obj(vec![(
            "with",
            Json::obj(vec![("amount", Json::int(20))]),
        )]))
        .unwrap();
        assert!(with_only.explicit_with());

        let legacy_with_to = CommandInvocation::from_json(&Json::obj(vec![
            ("to", Json::str("ORDER-7")),
            ("quantity", Json::int(3)),
        ]))
        .unwrap();
        assert!(!legacy_with_to.explicit_with());

        let legacy_no_to = CommandInvocation::from_json(&Json::obj(vec![(
            "amount",
            Json::int(20),
        )]))
        .unwrap();
        assert!(!legacy_no_to.explicit_with());

        let legacy_null_with = CommandInvocation::from_json(&Json::obj(vec![
            ("with", Json::Null),
            ("amount", Json::int(20)),
        ]))
        .unwrap();
        assert!(!legacy_null_with.explicit_with());
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

    // The `to:`-declared receiver is a real fact and must stay in `facts`; the Ruby side
    // raised AbsentArgument when it was stripped.
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

        // An explicit `to:` wins over either receiver field.
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

    // An explicitly empty `entities` refuses the same as an absent one.
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

    // `with:` beside a loose fact refuses TypeMismatch, as in Ruby, rather than UnknownArgument
    // from the args parser.
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

    // Step-envelope keys beside `with:` are not loose facts.
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
