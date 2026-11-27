//! A declared adapter's answer: the first `replies` or `refuses` row for the ask whose `where`
//! holds over the asking, read as data and never run.
//!
//! The runtime hands an adapter the record's held state merged with the ask's arguments, as
//! plain data, where a value object arrives as `{"value": ...}`. A row's `where` compares the
//! scalar inside such a wrapper, so `where: { beat: "beat-quiet" }` holds for
//! `{"beat": {"value": "beat-quiet"}}` and for `{"beat": "beat-quiet"}` alike.
//!
//! Every outcome is named. A row that matches answers with its `with` data and the asked fields
//! it is `echoing`, or refuses with its `saying`. An ask no row matches is refused with the
//! values it was asked with, so a fixture that lacks a case says which case it lacks.

use crate::emit::{self, JsonValue};
use crate::ir::{Adapter, Reply, ReplyOutcome};

/// What a declared adapter does with one asking.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    Answer(JsonValue),
    Refused(String),
}

impl Outcome {
    /// `{"answer": ...}` or `{"refused": "..."}`, the one line the runtime reads back.
    pub fn json(&self) -> JsonValue {
        match self {
            Self::Answer(value) => JsonValue::Object(vec![("answer".to_string(), value.clone())]),
            Self::Refused(text) => {
                JsonValue::Object(vec![("refused".to_string(), JsonValue::str(text.clone()))])
            }
        }
    }
}

/// Answers `ask` from `adapter`'s rows, in file order.
pub fn answer(adapter: &Adapter, ask: &str, asked: &JsonValue) -> Outcome {
    let rows: Vec<&Reply> = adapter
        .replies
        .iter()
        .filter(|row| row.ask == ask)
        .collect();
    if rows.is_empty() {
        return Outcome::Refused(format!("{} declares no reply for {ask}", adapter.name));
    }
    rows.iter().find(|row| holds(row, asked)).map_or_else(
        || unmatched(adapter, ask, &rows, asked),
        |row| outcome(row, asked),
    )
}

fn holds(row: &Reply, asked: &JsonValue) -> bool {
    row.matches.iter().all(|(field, wanted)| {
        field_of(asked, field).is_some_and(|got| unwrapped(got) == &emit::data_json(wanted))
    })
}

fn outcome(row: &Reply, asked: &JsonValue) -> Outcome {
    match &row.outcome {
        ReplyOutcome::Refuse { saying } => Outcome::Refused(saying.clone()),
        ReplyOutcome::Answer { with, echoing } => {
            let declared = with
                .as_ref()
                .map_or(JsonValue::Object(Vec::new()), emit::data_json);
            echoed(declared, echoing, &row.ask, asked)
        }
    }
}

/// The declared answer with each echoed field copied from the asking, as it was asked; an
/// echoed field replaces a declared one of the same name.
fn echoed(declared: JsonValue, echoing: &[String], ask: &str, asked: &JsonValue) -> Outcome {
    if echoing.is_empty() {
        return Outcome::Answer(declared);
    }
    let JsonValue::Object(mut pairs) = declared else {
        return Outcome::Answer(declared);
    };
    for field in echoing {
        let Some(value) = field_of(asked, field) else {
            return Outcome::Refused(format!(
                "{ask} echoes {field}, which the asking did not carry"
            ));
        };
        pairs.retain(|(key, _)| key != field);
        pairs.push((field.clone(), value.clone()));
    }
    Outcome::Answer(JsonValue::Object(pairs))
}

/// The refusal for an ask no row matched: the fields the rows match on, with what was asked.
fn unmatched(adapter: &Adapter, ask: &str, rows: &[&Reply], asked: &JsonValue) -> Outcome {
    let mut fields: Vec<&str> = Vec::new();
    for (field, _) in rows.iter().flat_map(|row| row.matches.iter()) {
        if !fields.contains(&field.as_str()) {
            fields.push(field);
        }
    }
    let values: Vec<String> = fields
        .iter()
        .map(|field| {
            let shown = field_of(asked, field)
                .map_or_else(|| "nothing".to_string(), |v| shown(unwrapped(v)));
            format!("{field}: {shown}")
        })
        .collect();
    Outcome::Refused(format!(
        "{} has no reply for {ask} where {}",
        adapter.name,
        values.join(", ")
    ))
}

fn field_of<'a>(asked: &'a JsonValue, field: &str) -> Option<&'a JsonValue> {
    let JsonValue::Object(pairs) = asked else {
        return None;
    };
    pairs
        .iter()
        .find(|(key, _)| key == field)
        .map(|(_, value)| value)
}

/// The scalar inside a value object's `{"value": ...}` wrapper, else the value itself.
fn unwrapped(value: &JsonValue) -> &JsonValue {
    match value {
        JsonValue::Object(pairs) if pairs.len() == 1 && pairs[0].0 == "value" => &pairs[0].1,
        _ => value,
    }
}

fn shown(value: &JsonValue) -> String {
    match value {
        JsonValue::String(text) => format!("\"{text}\""),
        JsonValue::Number(text) => text.clone(),
        JsonValue::Bool(b) => b.to_string(),
        JsonValue::Null => "nil".to_string(),
        other => emit::write(other).replace('\n', " "),
    }
}

#[cfg(test)]
#[path = "declared_tests.rs"]
mod tests;
