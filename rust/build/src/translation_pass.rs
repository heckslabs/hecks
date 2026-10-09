//! Rust port of the part of `Projector::Exporter::Translations` that a `translations/*.bluebook`
//! edge made of renames and moves needs: the declared rules plus the SQL expression
//! `Translation::RuleCompiler.compile_rules` builds for them.
//!
//! A rule kind this pass does not compile (convert, drop, retype, compute, rekey, backfill) is
//! refused by name, so a domain never ships an edge whose SQL was silently left out.

use std::path::Path;

use crate::json::Json;

/// One aggregate's rules, in declaration order.
struct Aggregate {
    name: String,
    was: Option<String>,
    renames: Vec<(String, String)>,
    moves: Vec<(String, String)>,
}

/// The `translations` IR list for the `.bluebook` files under `bluebook_dir/translations`, ordered
/// by file name (an era-step id), as the registry loads them.
pub fn edges(bluebook_dir: &Path) -> Result<Vec<Json>, String> {
    let Ok(entries) = std::fs::read_dir(bluebook_dir.join("translations")) else { return Ok(Vec::new()) };
    let mut paths: Vec<_> = entries
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| path.extension().and_then(|e| e.to_str()) == Some("bluebook"))
        .collect();
    paths.sort();
    let mut edges = Vec::new();
    for path in paths {
        let text = std::fs::read_to_string(&path).map_err(|e| format!("reading {}: {e}", path.display()))?;
        edges.push(edge(&text).map_err(|why| format!("{}: {why}", path.display()))?);
    }
    Ok(edges)
}

fn edge(text: &str) -> Result<Json, String> {
    let mut header: Option<(String, String, String)> = None;
    let mut aggregates: Vec<Aggregate> = Vec::new();
    for raw in text.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') || line == "end" {
            continue;
        }
        if let Some(rest) = line.strip_prefix("Hecks.data_translation") {
            header = Some((first_string(rest)?, keyword(rest, "from")?, keyword(rest, "to")?));
        } else if let Some(rest) = line.strip_prefix("aggregate ") {
            let was = keyword(rest, "was").ok();
            aggregates.push(Aggregate { name: first_string(rest)?, was, renames: Vec::new(), moves: Vec::new() });
        } else if let Some(rest) = line.strip_prefix("move ") {
            let aggregate = aggregates.last_mut().ok_or("a move outside an aggregate")?;
            aggregate.moves.push((first_word(rest)?, keyword(rest, "to")?));
        } else if let Some(rest) = line.strip_prefix("rename ") {
            let aggregate = aggregates.last_mut().ok_or("a rename outside an aggregate")?;
            aggregate.renames.push((first_word(rest)?, keyword(rest, "to")?));
        } else {
            return Err(format!(
                "hecks-build cannot compile the translation rule `{line}` yet (only rename and move are ported), \
                 so generate this domain with the Ruby toolchain"
            ));
        }
    }
    let (domain, from, to) = header.ok_or("no Hecks.data_translation header")?;
    Ok(Json::Object(vec![
        ("domain".into(), Json::String(domain)),
        ("from".into(), Json::String(from)),
        ("to".into(), Json::String(to)),
        ("retired".into(), Json::Array(Vec::new())),
        ("aggregates".into(), Json::Array(aggregates.iter().map(aggregate_json).collect())),
    ]))
}

fn aggregate_json(aggregate: &Aggregate) -> Json {
    let renames = aggregate.renames.iter().map(|(old, new)| (old.clone(), Json::String(new.clone()))).collect();
    let moves = aggregate
        .moves
        .iter()
        .map(|(from, to)| Json::Object(vec![("from".into(), Json::String(from.clone())), ("to".into(), Json::String(to.clone()))]))
        .collect();
    let empty = || Json::Array(Vec::new());
    Json::Object(vec![
        ("name".into(), Json::String(aggregate.name.clone())),
        ("was".into(), aggregate.was.clone().map_or(Json::Null, Json::String)),
        ("renames".into(), Json::Object(renames)),
        ("moves".into(), Json::Array(moves)),
        ("converts".into(), empty()),
        ("drops".into(), empty()),
        ("retypes".into(), empty()),
        ("computes".into(), empty()),
        ("rekeys".into(), empty()),
        ("backfills".into(), empty()),
        ("compiled_state_expression".into(), Json::String(compile(aggregate))),
        ("compiled_id_expression".into(), Json::Null),
    ])
}

/// `RuleCompiler.compile_rules`: renames, then moves, each wrapping the expression so far.
fn compile(aggregate: &Aggregate) -> String {
    let mut sql = "state".to_string();
    for (old, new) in &aggregate.renames {
        sql = format!("hecks_tr_rename({sql}, {}, {})", text_literal(old), text_literal(new));
    }
    for (from, to) in &aggregate.moves {
        sql = format!(
            "hecks_tr_move({sql}, {}, {}, {})",
            path_literal(from),
            path_literal(to),
            text_literal(&format!("move {from} to: {to}"))
        );
    }
    sql
}

fn text_literal(text: &str) -> String {
    format!("'{}'", text.replace('\'', "''"))
}

fn path_literal(path: &str) -> String {
    let segments: Vec<String> = path.split('.').map(text_literal).collect();
    format!("ARRAY[{}]::text[]", segments.join(", "))
}

/// The first `"quoted"` string of `text`.
fn first_string(text: &str) -> Result<String, String> {
    let open = text.find('"').ok_or_else(|| format!("no quoted name in `{text}`"))?;
    let rest = &text[open + 1..];
    let close = rest.find('"').ok_or_else(|| format!("unterminated string in `{text}`"))?;
    Ok(rest[..close].to_string())
}

/// The leading argument, a `:symbol` or a `"string"`, before the first comma.
fn first_word(text: &str) -> Result<String, String> {
    let word = text.split(',').next().unwrap_or_default().trim();
    let word = word.strip_prefix(':').unwrap_or(word).trim_matches('"');
    if word.is_empty() { Err(format!("no source in `{text}`")) } else { Ok(word.to_string()) }
}

/// The value of `key: value` in `text`, a string or a symbol.
fn keyword(text: &str, key: &str) -> Result<String, String> {
    let marker = format!("{key}:");
    let at = text.find(&marker).ok_or_else(|| format!("no `{key}:` in `{text}`"))?;
    let value = text[at + marker.len()..].trim_start();
    if let Some(symbol) = value.strip_prefix(':') {
        let end = symbol.find(|c: char| !(c.is_alphanumeric() || c == '_')).unwrap_or(symbol.len());
        return Ok(symbol[..end].to_string());
    }
    first_string(value)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn compiles_moves_as_ruby_does() {
        let text = "Hecks.data_translation \"Pizzas\", from: \"e3f3d7\", to: \"77625c\" do\n  aggregate \"Order\", was: \"Pizza\" do\n    move :price_cents, to: \"pizza.price_cents\"\n    move :size,         to: \"pizza.size\"\n  end\nend\n";
        let json = crate::json::write(&edge(text).unwrap());
        assert!(json.contains("hecks_tr_move(hecks_tr_move(state, ARRAY['price_cents']::text[], ARRAY['pizza', 'price_cents']::text[], 'move price_cents to: pizza.price_cents'), ARRAY['size']::text[], ARRAY['pizza', 'size']::text[], 'move size to: pizza.size')"));
    }

    #[test]
    fn refuses_a_rule_it_cannot_compile() {
        let text = "Hecks.data_translation \"A\", from: \"1\", to: \"2\" do\n  aggregate \"B\" do\n    compute :a, to: \"b\", sql: \"1\"\n  end\nend\n";
        assert!(edge(text).unwrap_err().contains("cannot compile"));
    }
}
