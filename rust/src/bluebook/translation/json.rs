//! Translation IR as JSON — the shape `bin/ir --translations` prints on
//! the Ruby side, so `bin/parity`'s translation stage can diff the two
//! parsers' readings through `bin/canonicalise` exactly the way it
//! already diffs domain IR. `values:` tables serialize as `[key, value]`
//! pairs, never an object, because JSON object keys are always strings
//! and a convert's keys are typed.

use super::ir::{ConvertLiteral, Translation};
use serde_json::{json, Map, Value};

pub fn translation_to_value(translation: &Translation) -> Value {
    let aggregates: Vec<Value> = translation
        .aggregates
        .iter()
        .map(|aggregate| {
            let mut renames = Map::new();
            for (old, new) in &aggregate.renames {
                renames.insert(old.clone(), Value::String(new.clone()));
            }
            json!({
                "name": aggregate.name,
                "was": aggregate.was,
                "renames": renames,
                "moves": aggregate.moves.iter()
                    .map(|declared| json!({ "from": declared.from, "to": declared.to }))
                    .collect::<Vec<_>>(),
                "converts": aggregate.converts.iter()
                    .map(|declared| json!({
                        "from": declared.from,
                        "to": declared.to,
                        "values": declared.values.iter()
                            .map(|(key, value)| json!([literal(key), literal(value)]))
                            .collect::<Vec<_>>(),
                    }))
                    .collect::<Vec<_>>(),
                "drops": aggregate.drops,
                "retypes": aggregate.retypes.iter()
                    .map(|declared| json!({ "from": declared.from, "to": declared.to }))
                    .collect::<Vec<_>>(),
                "computes": aggregate.computes.iter()
                    .map(|declared| json!({ "from": declared.from, "to": declared.to, "sql": declared.sql }))
                    .collect::<Vec<_>>(),
            })
        })
        .collect();

    json!({
        "domain": translation.domain,
        "from": translation.from,
        "to": translation.to,
        "retired": translation.retired,
        "aggregates": aggregates,
    })
}

fn literal(value: &ConvertLiteral) -> Value {
    match value {
        ConvertLiteral::Str(text) => Value::String(text.clone()),
        ConvertLiteral::Bool(flag) => Value::Bool(*flag),
        ConvertLiteral::Int(number) => json!(number),
    }
}
