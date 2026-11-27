//! One `replies` or `refuses` row of a declared adapter, read and judged.
//!
//! A declared adapter answers its port from data, so every value in a row must be data: a
//! `where:` hash of scalars, a `with:` hash (or, for a port-answered query, a list of hashes) of
//! strings, integers, booleans, nil, lists and hashes, an `echoing:` list of symbols, and a
//! `saying:` string. A float, a bare word, a constant or a symbol inside `with:` is refused here,
//! so nothing in a declared adapter can be read as code by any loader.

use crate::diag::{Diagnostic, ParseResult};
use crate::ir::{Reply, ReplyOutcome};
use crate::parse::ArgumentGateResult;
use crate::ruby_value::{self, Value};

/// Reads the row a `replies "Ask", ...` or `refuses "Ask", ...` line declares.
pub(super) fn read(
    file: &str,
    line: usize,
    word: &str,
    ask: String,
    args: &ArgumentGateResult,
) -> ParseResult<Reply> {
    let refuse = |message: String| Diagnostic::new(file, line, format!("'{word}' {message}"));
    if ask.trim().is_empty() {
        return Err(refuse("needs the ask it answers".to_string()));
    }
    let matches = match crate::parse::named_raw(args, "where") {
        Some(raw) => matches(raw).map_err(refuse)?,
        None => Vec::new(),
    };
    let outcome = if word == "refuses" {
        let saying = crate::parse::named_raw(args, "saying")
            .map(ruby_value::read)
            .ok_or_else(|| refuse("needs saying: the words of its refusal".to_string()))?;
        match saying {
            Value::Str(text) if !text.trim().is_empty() => ReplyOutcome::Refuse { saying: text },
            _ => return Err(refuse("saying: must be a string that says why".to_string())),
        }
    } else {
        let with = match crate::parse::named_raw(args, "with") {
            Some(raw) => Some(answer(raw).map_err(refuse)?),
            None => None,
        };
        let echoing = match crate::parse::named_raw(args, "echoing") {
            Some(raw) => echoing(raw).map_err(refuse)?,
            None => Vec::new(),
        };
        if !echoing.is_empty() && matches!(with, Some(Value::Array(_))) {
            return Err(refuse(
                "echoing: copies asked fields into one answer, not into a list of rows".to_string(),
            ));
        }
        ReplyOutcome::Answer { with, echoing }
    };
    Ok(Reply {
        ask,
        matches,
        outcome,
    })
}

/// `where: { field: "value", ... }`: asked field names to the scalars they must equal.
fn matches(raw: &str) -> Result<Vec<(String, Value)>, String> {
    let Value::Hash(pairs) = ruby_value::read(raw) else {
        return Err(format!(
            "where: ({}) must be a hash of asked fields",
            raw.trim()
        ));
    };
    for (key, value) in &pairs {
        if !is_scalar(value) {
            return Err(format!(
                "where: {key} must equal a string, integer, true, false or nil"
            ));
        }
    }
    Ok(pairs)
}

/// `with:` — one answer hash, or a list of answer rows for a query that returns a list.
fn answer(raw: &str) -> Result<Value, String> {
    let value = ruby_value::read(raw);
    match &value {
        Value::Hash(_) => {}
        Value::Array(rows) if rows.iter().all(|row| matches!(row, Value::Hash(_))) => {}
        _ => {
            return Err(format!(
                "with: ({}) must be a hash, or a list of hashes for a query's rows",
                raw.trim()
            ))
        }
    }
    data(&value).map(|()| value)
}

/// `echoing: [:field, ...]`: the asked fields copied into the answer as they were asked.
fn echoing(raw: &str) -> Result<Vec<String>, String> {
    let Value::Array(items) = ruby_value::read(raw) else {
        return Err(format!(
            "echoing: ({}) must be a list of symbols",
            raw.trim()
        ));
    };
    items
        .into_iter()
        .map(|item| match item {
            Value::Symbol(name) if !name.is_empty() => Ok(name),
            other => Err(format!(
                "echoing: names asked fields as symbols, not {}",
                ruby_value::render(&other)
            )),
        })
        .collect()
}

const fn is_scalar(value: &Value) -> bool {
    matches!(
        value,
        Value::Nil | Value::Bool(_) | Value::Int(_) | Value::Str(_)
    )
}

/// Whether every value in an answer is data JSON carries as it is written.
fn data(value: &Value) -> Result<(), String> {
    match value {
        Value::Nil | Value::Bool(_) | Value::Int(_) | Value::Str(_) => Ok(()),
        Value::Hash(pairs) => pairs.iter().try_for_each(|(_, v)| data(v)),
        Value::Array(items) => items.iter().try_for_each(data),
        Value::Float(_) => Err(format!(
            "with: holds {}; a declared answer counts in integers",
            ruby_value::render(value)
        )),
        Value::Symbol(name) => Err(format!(
            "with: holds :{name}, which is not data; copy an asked field into the answer with echoing:"
        )),
        Value::Bare(text) => Err(format!(
            "with: holds {text}, which is not data: write a string, integer, true, false, nil, list or hash"
        )),
    }
}
