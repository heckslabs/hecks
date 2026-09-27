//! Reference port of `Lineage#translate` (rename, move, convert, drop, backfill).
//! `crate::mint`'s Layer-2 audit gate diffs this against the compiled SQL at mint time.

use serde_json::{Map, Value};

/// Applies one edge's rename/move/convert/drop/backfill rules to `state`.
/// `state` must be a JSON object; anything else is a caller bug, not a translation failure.
pub fn translate(edge_aggregate_raw: &Value, state: &Value) -> anyhow::Result<Value> {
    let Value::Object(source) = state else {
        anyhow::bail!("reference_transform::translate given a non-object state: {state}");
    };
    let mut state = source.clone();

    if let Some(renames) = edge_aggregate_raw.get("renames").and_then(Value::as_object) {
        for (old_name, new_name) in renames {
            let Some(new_name) = new_name.as_str() else { continue };
            if let Some(value) = state.remove(old_name) {
                state.insert(new_name.to_string(), value);
            }
        }
    }

    if let Some(moves) = edge_aggregate_raw.get("moves").and_then(Value::as_array) {
        for mv in moves {
            let from = mv.get("from").and_then(Value::as_str).unwrap_or_default();
            let to = mv.get("to").and_then(Value::as_str).unwrap_or_default();
            apply_move(&mut state, from, to)?;
        }
    }

    if let Some(converts) = edge_aggregate_raw.get("converts").and_then(Value::as_array) {
        for cv in converts {
            let from = cv.get("from").and_then(Value::as_str).unwrap_or_default();
            let to = cv.get("to").and_then(Value::as_str).unwrap_or_default();
            let values = cv.get("values").and_then(Value::as_array).cloned().unwrap_or_default();
            apply_convert(&mut state, from, to, &values)?;
        }
    }

    if let Some(drops) = edge_aggregate_raw.get("drops").and_then(Value::as_array) {
        for name in drops {
            if let Some(name) = name.as_str() {
                let (top, member) = split_path(name);
                extract(&mut state, top, member);
            }
        }
    }

    // Runs last, after renames/moves/converts/drops, and only fills a gap nothing
    // already answered — dotted-path aware like the rules above, matching
    // `Lineage#apply_backfill`.
    if let Some(backfills) = edge_aggregate_raw.get("backfills").and_then(Value::as_array) {
        for bf in backfills {
            let Some(name) = bf.get("name").and_then(Value::as_str) else { continue };
            let (top, member) = split_path(name);
            let already_present = match member {
                None => state.contains_key(top),
                Some(member) => state.get(top).and_then(Value::as_object).is_some_and(|obj| obj.contains_key(member)),
            };
            if !already_present {
                let default = bf.get("default").cloned().unwrap_or(Value::Null);
                insert(&mut state, top, member, default, &format!("backfill {name}"))?;
            }
        }
    }

    Ok(Value::Object(state))
}

/// Splits a dotted path into its top-level key and optional nested member
/// (`Lineage`'s own `split(".", 2)`; at most one member deep).
fn split_path(path: &str) -> (&str, Option<&str>) {
    match path.split_once('.') {
        Some((top, member)) => (top, Some(member)),
        None => (path, None),
    }
}

/// Removes `top[.member]` from `state`, dropping the now-empty parent key too.
/// `None` means the path was already absent — not an error; callers no-op on it.
fn extract(state: &mut Map<String, Value>, top: &str, member: Option<&str>) -> Option<Value> {
    match member {
        None => state.remove(top),
        Some(member) => {
            let nested = state.get_mut(top)?.as_object_mut()?;
            let value = nested.remove(member)?;
            if nested.is_empty() {
                state.remove(top);
            }
            Some(value)
        }
    }
}

/// Inserts `value` at `top[.member]`. Refuses when `top` already holds a
/// non-object value, since nesting into it would silently discard that value.
fn insert(state: &mut Map<String, Value>, top: &str, member: Option<&str>, value: Value, rule: &str) -> anyhow::Result<()> {
    let Some(member) = member else {
        state.insert(top.to_string(), value);
        return Ok(());
    };

    if let Some(existing) = state.get(top) {
        if !existing.is_object() {
            anyhow::bail!(
                "cannot {rule}: {top} already holds {existing}, not a value this can nest under -- moving into \
                 it would discard that value silently. Rename or drop {top} first."
            );
        }
    }

    state.entry(top.to_string()).or_insert_with(|| Value::Object(Map::new())).as_object_mut().unwrap().insert(member.to_string(), value);
    Ok(())
}

fn apply_move(state: &mut Map<String, Value>, from: &str, to: &str) -> anyhow::Result<()> {
    let (old_top, old_member) = split_path(from);
    let (new_top, new_member) = split_path(to);
    let Some(value) = extract(state, old_top, old_member) else { return Ok(()) };
    insert(state, new_top, new_member, value, &format!("move {from} to: {to}"))
}

/// A move whose value is looked up in `values` (`[key, value]` pairs, not a
/// JSON object, since a raw value's type may not be a string); an unmapped value refuses.
fn apply_convert(state: &mut Map<String, Value>, from: &str, to: &str, values: &[Value]) -> anyhow::Result<()> {
    let (old_top, old_member) = split_path(from);
    let (new_top, new_member) = split_path(to);
    let Some(raw) = extract(state, old_top, old_member) else { return Ok(()) };

    let mapped = values.iter().find_map(|pair| {
        let pair = pair.as_array()?;
        (pair.len() == 2 && pair[0] == raw).then(|| pair[1].clone())
    });
    let Some(mapped) = mapped else {
        anyhow::bail!("cannot translate {from}: {raw} has no mapping in its convert's values: table. Add {raw} => ... to cover it.");
    };

    insert(state, new_top, new_member, mapped, &format!("convert {from} to: {to}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn a_bare_rename_moves_the_value_across_unconditionally() {
        let rules = json!({ "renames": { "cost": "amount" } });
        let state = json!({ "cost": 5, "other": "x" });
        let out = translate(&rules, &state).unwrap();
        assert_eq!(out, json!({ "amount": 5, "other": "x" }));
    }

    #[test]
    fn a_rename_naming_an_absent_source_is_a_silent_no_op() {
        let rules = json!({ "renames": { "cost": "amount" } });
        let state = json!({ "other": "x" });
        let out = translate(&rules, &state).unwrap();
        assert_eq!(out, json!({ "other": "x" }));
    }

    #[test]
    fn a_move_lands_a_top_level_field_inside_a_brand_new_nested_value_object() {
        let rules = json!({ "moves": [{ "from": "weight", "to": "contents.weight" }] });
        let state = json!({ "weight": 12 });
        let out = translate(&rules, &state).unwrap();
        assert_eq!(out, json!({ "contents": { "weight": 12 } }));
    }

    #[test]
    fn a_move_out_of_a_nested_member_deletes_the_now_empty_parent_too() {
        let rules = json!({ "moves": [{ "from": "price.currency", "to": "currency" }] });
        let state = json!({ "price": { "currency": "usd" } });
        let out = translate(&rules, &state).unwrap();
        assert_eq!(out, json!({ "currency": "usd" }));
    }

    #[test]
    fn a_move_out_of_a_nested_member_leaves_the_parent_when_siblings_remain() {
        let rules = json!({ "moves": [{ "from": "price.currency", "to": "currency" }] });
        let state = json!({ "price": { "currency": "usd", "cents": 500 } });
        let out = translate(&rules, &state).unwrap();
        assert_eq!(out, json!({ "price": { "cents": 500 }, "currency": "usd" }));
    }

    #[test]
    fn a_move_into_a_destination_already_holding_a_non_object_value_refuses() {
        let rules = json!({ "moves": [{ "from": "detail", "to": "team.detail" }] });
        let state = json!({ "detail": "x", "team": "team-1" });
        let err = translate(&rules, &state).unwrap_err();
        assert!(err.to_string().contains("team already holds"), "{err}");
    }

    #[test]
    fn a_convert_maps_a_recognized_raw_value() {
        let rules = json!({ "converts": [{ "from": "kind", "to": "kind", "values": [["a", "alpha"], ["b", "beta"]] }] });
        let state = json!({ "kind": "a" });
        let out = translate(&rules, &state).unwrap();
        assert_eq!(out, json!({ "kind": "alpha" }));
    }

    #[test]
    fn a_convert_meeting_an_unmapped_raw_value_refuses() {
        let rules = json!({ "converts": [{ "from": "kind", "to": "kind", "values": [["a", "alpha"]] }] });
        let state = json!({ "kind": "z" });
        let err = translate(&rules, &state).unwrap_err();
        assert!(err.to_string().contains("no mapping"), "{err}");
    }

    #[test]
    fn a_drop_removes_a_nested_member_and_its_now_empty_parent() {
        let rules = json!({ "drops": ["price.currency"] });
        let state = json!({ "price": { "currency": "usd" }, "kept": true });
        let out = translate(&rules, &state).unwrap();
        assert_eq!(out, json!({ "kept": true }));
    }

    #[test]
    fn a_backfill_only_fills_a_gap_never_overwrites_a_value_that_already_made_it_across() {
        let rules = json!({ "backfills": [{ "name": "status", "default": "pending" }] });

        let absent = translate(&rules, &json!({})).unwrap();
        assert_eq!(absent, json!({ "status": "pending" }));

        let present = translate(&rules, &json!({ "status": "shipped" })).unwrap();
        assert_eq!(present, json!({ "status": "shipped" }));
    }

    #[test]
    fn rules_apply_in_order_renames_then_moves_then_converts_then_drops_then_backfills_last() {
        // A rename feeds a move's own source; a backfill would clobber
        // the outcome if it ran anywhere but last.
        let rules = json!({
            "renames": { "old_name": "mid_name" },
            "moves": [{ "from": "mid_name", "to": "final.name" }],
            "backfills": [{ "name": "final", "default": { "name": "should never win" } }]
        });
        let out = translate(&rules, &json!({ "old_name": "Alice" })).unwrap();
        assert_eq!(out, json!({ "final": { "name": "Alice" } }));
    }
}
