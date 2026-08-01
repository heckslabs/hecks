//! Translates a stored record written under an old shape into the one
//! the current bluebook declares — a renamed attribute, a renamed
//! aggregate, or a field crossing a value-object boundary. Mirrors
//! lib/hecksagain/ports/persistence/lineage.rb: the port owns the
//! meaning, adapters stay oblivious.

use crate::bluebook::translation::ir::{ConvertLiteral, Translation, TranslationCompute, TranslationConvert, TranslationRetype};
use crate::runtime::{AggregateState, Value};
use std::collections::HashMap;

pub struct Lineage {
    renames: Vec<(String, String)>,
    moves: Vec<(String, String)>,
    converts: Vec<TranslationConvert>,
    drops: Vec<String>,
    retypes: Vec<TranslationRetype>,
    computes: Vec<TranslationCompute>,
    /// The declared name a rename came from (matches the held bluebook's
    /// own aggregate names); `None` unless the aggregate itself was
    /// renamed.
    pub ancestor_name: Option<String>,
    /// The ancestor's derived, snake_case storage name.
    pub ancestor_storage_name: Option<String>,
}

impl Lineage {
    pub fn for_aggregate(translations: &[Translation], domain: &str, aggregate_name: &str) -> Option<Self> {
        let translation = translations
            .iter()
            .find(|candidate| candidate.domain == domain && candidate.for_aggregate(aggregate_name).is_some())?;
        let declared = translation.for_aggregate(aggregate_name)?;

        let renamed_aggregate = declared.was.as_deref().is_some_and(|was| was != aggregate_name);
        let ancestor_name = renamed_aggregate.then(|| declared.was.clone().unwrap());
        let ancestor_storage_name = ancestor_name.as_deref().map(crate::naming::snake);

        Some(Lineage {
            renames: declared.renames.clone(),
            moves: declared.moves.iter().map(|m| (m.from.clone(), m.to.clone())).collect(),
            converts: declared.converts.clone(),
            drops: declared.drops.clone(),
            retypes: declared.retypes.clone(),
            computes: declared.computes.clone(),
            ancestor_name,
            ancestor_storage_name,
        })
    }

    /// Whether any rule in this edge is a compute — the one rule kind
    /// with no in-process implementation at all. An aggregate carrying
    /// one refuses to boot anywhere but Postgres, per-rule and by name,
    /// before the general drift machinery says anything vaguer.
    pub fn has_computes(&self) -> bool {
        !self.computes.is_empty()
    }

    /// Whether a declared retype says the pair of TYPE names means the
    /// same shape — a value object or entity whose own name changed with
    /// its members intact. Nothing in the stored data carries the type
    /// name, so this never moves a value; it only satisfies the era
    /// diff's literal type-name comparison.
    pub fn retype_covers(&self, held_type: &str, current_type: &str) -> bool {
        self.retypes.iter().any(|retype| retype.from == held_type && retype.to == current_type)
    }

    /// Whether this translation names `path` as an old key it accounts
    /// for — the rename, move, or convert it came from, or an explicit
    /// drop. `path` is a bare name ("cost") or a dotted value-object
    /// member ("price.currency"); a rule covering the WHOLE top-level
    /// attribute (a rename, a top-level move/convert/drop) also covers
    /// anything nested under it, since the whole value travels or goes
    /// away together. Used to catch a field — or a value object's own
    /// member — that vanished (or silently changed type) without
    /// anything explaining it, even when some OTHER field is covered.
    pub fn explains(&self, path: &str) -> bool {
        let top = top_level(path);
        self.renames.iter().any(|(old, _)| old == top)
            || self.moves.iter().any(|(from, _)| from == path || top_level(from) == top)
            || self.converts.iter().any(|c| c.from == path || top_level(&c.from) == top)
            || self.drops.iter().any(|d| d == path || top_level(d) == top)
            || self.computes.iter().any(|c| c.from == path || top_level(&c.from) == top)
    }

    /// The reference semantics for the five PORTABLE rule kinds —
    /// renames, then moves, then converts, then drops — applied to a
    /// full state (not a raw journal entry): both an already-resolved
    /// own record and an ancestor's already-resolved record go through
    /// the same transform. `retype` moves nothing (stored state never
    /// carries a type name) and `compute` is deliberately not applied
    /// here: its SQL is its only implementation, so this transform
    /// neither imitates nor checks it — the source field passes through
    /// untouched, and the audit verifies compute output against the
    /// matview alone.
    pub fn translate(&self, state: &AggregateState) -> Result<AggregateState, String> {
        let mut fields = state.fields.clone();

        for (old_name, new_name) in &self.renames {
            if let Some(value) = fields.remove(old_name) {
                fields.insert(new_name.clone(), value);
            }
        }
        for (from, to) in &self.moves {
            apply_move(&mut fields, from, to);
        }
        for convert in &self.converts {
            apply_convert(&mut fields, convert)?;
        }
        for name in &self.drops {
            apply_drop(&mut fields, name);
        }

        let mut translated = AggregateState::new(&state.id);
        translated.fields = fields;
        translated.deleted = state.deleted;
        Ok(translated)
    }
}

fn top_level(path: &str) -> &str {
    path.split('.').next().unwrap_or(path)
}

fn split_path(path: &str) -> (&str, Option<&str>) {
    match path.split_once('.') {
        Some((top, member)) => (top, Some(member)),
        None => (path, None),
    }
}

fn extract(fields: &mut HashMap<String, Value>, top: &str, member: Option<&str>) -> Option<Value> {
    let Some(member) = member else {
        return fields.remove(top);
    };
    let value = match fields.get_mut(top) {
        Some(Value::Map(nested)) => nested.remove(member),
        _ => None,
    };
    if value.is_some() {
        if let Some(Value::Map(nested)) = fields.get(top) {
            if nested.is_empty() {
                fields.remove(top);
            }
        }
    }
    value
}

fn insert(fields: &mut HashMap<String, Value>, top: &str, member: Option<&str>, value: Value) {
    match member {
        None => {
            fields.insert(top.to_string(), value);
        }
        Some(member) => match fields.get_mut(top) {
            Some(Value::Map(nested)) => {
                nested.insert(member.to_string(), value);
            }
            _ => {
                let mut nested = HashMap::new();
                nested.insert(member.to_string(), value);
                fields.insert(top.to_string(), Value::Map(nested));
            }
        },
    }
}

fn apply_drop(fields: &mut HashMap<String, Value>, path: &str) {
    let (top, member) = split_path(path);
    extract(fields, top, member);
}

fn apply_move(fields: &mut HashMap<String, Value>, from: &str, to: &str) {
    let (old_top, old_member) = split_path(from);
    let (new_top, new_member) = split_path(to);
    if let Some(value) = extract(fields, old_top, old_member) {
        insert(fields, new_top, new_member, value);
    }
}

fn apply_convert(fields: &mut HashMap<String, Value>, convert: &TranslationConvert) -> Result<(), String> {
    let (old_top, old_member) = split_path(&convert.from);
    let (new_top, new_member) = split_path(&convert.to);

    let Some(raw) = extract(fields, old_top, old_member) else {
        return Ok(());
    };

    let Some(raw_literal) = value_to_literal(&raw) else {
        return Err(format!(
            "cannot translate {}: {:?} has no mapping in its convert's values: table. Add {:?} => ... to cover it.",
            convert.from, raw, raw
        ));
    };

    let mapped = convert.values.iter().find(|(key, _)| *key == raw_literal).map(|(_, value)| value.clone());
    let Some(mapped) = mapped else {
        return Err(format!(
            "cannot translate {}: {} has no mapping in its convert's values: table. Add {} => ... to cover it.",
            convert.from,
            raw_literal.render(),
            raw_literal.render()
        ));
    };

    insert(fields, new_top, new_member, literal_to_value(&mapped));
    Ok(())
}

/// The typed shapes a convert's `values:` table can key on — string,
/// boolean, integer. Anything else (a nested value object, a list) has
/// no possible entry in the table and refuses the same way an unmapped
/// value does.
fn value_to_literal(value: &Value) -> Option<ConvertLiteral> {
    match value {
        Value::Str(s) => Some(ConvertLiteral::Str(s.clone())),
        Value::Bool(b) => Some(ConvertLiteral::Bool(*b)),
        Value::Int(i) => Some(ConvertLiteral::Int(*i)),
        _ => None,
    }
}

fn literal_to_value(literal: &ConvertLiteral) -> Value {
    match literal {
        ConvertLiteral::Str(s) => Value::Str(s.clone()),
        ConvertLiteral::Bool(b) => Value::Bool(*b),
        ConvertLiteral::Int(i) => Value::Int(*i),
    }
}
