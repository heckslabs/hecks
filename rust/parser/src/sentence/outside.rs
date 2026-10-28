//! What an examples step does besides running a command: a port announcing a fact to the
//! bluebook, and a query.
//!
//! A port is named like a person who acts, `the payment gateway`, and its operation is the verb:
//! `the payment gateway receives it with amount 1200 cents`. A query is run by name:
//! `Chris runs the available query`. Every name is checked against the bluebook, and a name that
//! reads as none is refused with the wordings that would.

use super::command_step::{base_forms, third_person};
use super::names::spoken;
use crate::ir;
use crate::render_ruby::string as ruby_string;

/// The aggregate a port belongs to, the port, and one of its operations.
pub(super) type Arrival<'c> = (&'c ir::Aggregate, &'c ir::DomainPort, &'c ir::PortOperation);

/// A query and the aggregate that declares it.
pub(super) type Lookup<'c> = (&'c ir::Aggregate, &'c ir::Query);

/// What a step does: run a command, have a port announce a fact, or run a query.
#[derive(Clone, Copy)]
pub(super) enum Action<'c> {
    Command(&'c ir::Command),
    Arrival {
        port: &'c ir::DomainPort,
        operation: &'c ir::PortOperation,
    },
    Query(&'c ir::Query),
}

impl<'c> Action<'c> {
    /// The command, when the step runs one.
    pub(super) const fn command(&self) -> Option<&'c ir::Command> {
        match self {
            Self::Command(command) => Some(command),
            _ => None,
        }
    }

    /// How a refusal names it: `purchase`, `receive`, `available`.
    pub(super) fn spoken(&self) -> String {
        match self {
            Self::Command(command) => spoken(&command.name),
            Self::Arrival { operation, .. } => spoken(&operation.name),
            Self::Query(query) => spoken(&query.name),
        }
    }

    /// The events the action announces itself, before any policy answers them.
    pub(super) fn first_events(&self) -> Vec<String> {
        match self {
            Self::Command(command) => command.emits.clone(),
            Self::Arrival { operation, .. } => operation.emits.clone(),
            Self::Query(_) => Vec::new(),
        }
    }
}

/// The port operation a step's `who` and verb name: `the payment gateway receives it`. `None`
/// when `who` names no port, so it is a person or a role. Only operations the outside calls in
/// are read; an operation the domain asks through is not an arrival.
pub(super) fn arrival<'c>(
    declaration: &'c ir::Bluebook,
    who: &str,
    verb: &str,
) -> Option<Result<Arrival<'c>, Vec<String>>> {
    let named = who
        .strip_prefix("the ")
        .or_else(|| who.strip_prefix("The "))?
        .to_lowercase();
    let (aggregate, port) = declaration
        .aggregates
        .iter()
        .flat_map(|aggregate| aggregate.ports.iter().map(move |port| (aggregate, port)))
        .find(|(_, port)| spoken(&port.name) == named)?;
    let forms = base_forms(verb);
    let inbound = || {
        port.operations
            .iter()
            .filter(|operation| !operation.outbound)
    };
    Some(
        inbound()
            .find(|operation| forms.contains(&spoken(&operation.name)))
            .map(|operation| (aggregate, port, operation))
            .ok_or_else(|| {
                inbound()
                    .map(|operation| wording(&named, operation))
                    .collect()
            }),
    )
}

/// How a step reads for an operation: `the payment gateway receives it`.
fn wording(port: &str, operation: &ir::PortOperation) -> String {
    format!("the {port} {} it", third_person(&spoken(&operation.name)))
}

/// The query a step names: `the available query` is `Available`. A query is looked for by its
/// spoken name among the queries of every aggregate.
pub(super) fn query_named<'c>(
    declaration: &'c ir::Bluebook,
    words: &str,
) -> Result<Lookup<'c>, Vec<String>> {
    let wanted = words.trim().to_lowercase();
    let all = || {
        declaration.aggregates.iter().flat_map(|aggregate| {
            aggregate
                .queries
                .iter()
                .map(move |query| (aggregate, query))
        })
    };
    all()
        .find(|(_, query)| spoken(&query.name) == wanted)
        .ok_or_else(|| {
            all()
                .map(|(_, query)| format!("runs the {} query", spoken(&query.name)))
                .collect()
        })
}

/// Whether `noun` names the aggregate's records, one or several: `order` or `orders`.
pub(super) fn names_records(noun: &str, aggregate: &ir::Aggregate) -> bool {
    let name = spoken(&aggregate.name);
    let noun = noun.trim().to_lowercase();
    noun == name || noun == format!("{name}s")
}

/// The Ruby text of the value `its name is …` gives: a quoted text, a number, or `not set`.
pub(super) fn field_value(text: &str) -> Result<String, String> {
    let trimmed = text.trim();
    let text = trimmed.strip_suffix('.').unwrap_or(trimmed);
    if text == "not set" {
        return Ok("nil".to_string());
    }
    if let Some(inner) = text
        .strip_prefix('"')
        .and_then(|rest| rest.strip_suffix('"'))
    {
        return Ok(ruby_string(inner));
    }
    if text.parse::<i64>().is_ok() || text.parse::<f64>().is_ok() {
        return Ok(text.to_string());
    }
    Err(format!(
        "'{text}' is not a value I can compare; write a quoted text, a number, or `not set`"
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_field_value_is_a_text_a_number_or_not_set() {
        assert_eq!(field_value("\"Only One\""), Ok("\"Only One\"".to_string()));
        assert_eq!(field_value("12"), Ok("12".to_string()));
        assert_eq!(field_value("not set"), Ok("nil".to_string()));
        assert!(field_value("maybe").is_err());
    }

    #[test]
    fn a_noun_names_the_records_in_either_number() {
        let aggregate = ir::Aggregate {
            name: "Order".to_string(),
            ..Default::default()
        };
        assert!(names_records("orders", &aggregate));
        assert!(names_records("Order", &aggregate));
        assert!(!names_records("pizza", &aggregate));
    }

    #[test]
    fn a_port_is_named_like_a_person_who_acts() {
        let declaration = ir::Bluebook {
            aggregates: vec![ir::Aggregate {
                name: "Order".to_string(),
                ports: vec![ir::DomainPort {
                    name: "PaymentGateway".to_string(),
                    operations: vec![ir::PortOperation {
                        name: "Receive".to_string(),
                        ..Default::default()
                    }],
                }],
                ..Default::default()
            }],
            ..Default::default()
        };
        assert!(matches!(
            arrival(&declaration, "the payment gateway", "receives"),
            Some(Ok(_))
        ));
        assert!(arrival(&declaration, "Chris", "receives").is_none());
        let Some(Err(wordings)) = arrival(&declaration, "the payment gateway", "sends") else {
            panic!("a verb the port lacks is refused");
        };
        assert_eq!(wordings, ["the payment gateway receives it"]);
    }
}
