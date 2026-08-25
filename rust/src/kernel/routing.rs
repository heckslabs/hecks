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
    /// mixed command-args object. `to` or `with` selects the explicit form.
    pub fn from_json(value: &Json) -> Result<Self, Refusal> {
        let target = value.get("to");
        let explicit_facts = value.get("with");
        if target.is_none() && explicit_facts.is_none() {
            return Ok(Self {
                route: None,
                facts: value.clone(),
            });
        }

        if value.get("args").is_some() {
            return Err(routing_refusal("cannot combine to/with with legacy args"));
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
}
