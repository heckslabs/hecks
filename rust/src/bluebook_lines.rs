//! bluebook_lines - the line-level readers.
//!
//! Cherry-picked in SHAPE from the Hecks parser (rust/src/parser.rs,
//! parser_helpers.rs), which says of itself: "Not a full Ruby parser - just
//! enough to read Bluebook declarations." That is the right ambition. A
//! .bluebook file is Ruby, but it is a deliberately small subset of Ruby, and
//! matching on its structure is honest where pretending to be a Ruby parser
//! would not be.
//!
//! Only what the pizzas grammar actually uses is here. Every reader that is
//! missing is missing on purpose - an unrecognised line is REFUSED by the
//! parser above, never skipped, so the gap announces itself instead of
//! silently dropping a declaration.

/// The first double-quoted string on a line: `vision "..."` -> `...`
pub fn quoted(line: &str) -> Option<String> {
    let start = line.find('"')?;
    let rest = &line[start + 1..];
    let end = rest.find('"')?;
    Some(rest[..end].to_string())
}

/// The first `:symbol` on a line: `attribute :name, String` -> `name`
pub fn symbol(line: &str) -> Option<String> {
    let start = line.find(':')?;
    let rest = &line[start + 1..];
    let end = rest
        .find(|c: char| !c.is_alphanumeric() && c != '_')
        .unwrap_or(rest.len());
    let name = &rest[..end];
    if name.is_empty() {
        None
    } else {
        Some(name.to_string())
    }
}

/// Does this line close a `do ... end` block?
///
/// There is deliberately no `opens_block`: each parse function is entered
/// BECAUSE its keyword was recognised, so it already knows a block opened. A
/// general opener test would be a second, weaker way of knowing the same
/// thing.
pub fn closes_block(line: &str) -> bool {
    line.trim() == "end"
}

/// The predicate body of `given("...") { expr }` or `invariant("...") { expr }`.
///
/// The brace is found AFTER the closing paren of the description, so a
/// description containing a brace cannot be mistaken for the body.
pub fn brace_body(line: &str) -> Option<String> {
    let paren = line.find(')')?;
    let open = line[paren..].find('{')? + paren;
    let close = line.rfind('}')?;
    if close <= open {
        return None;
    }
    Some(line[open + 1..close].to_string())
}

/// One meaning, one text. Must agree with
/// lib/hecksagain/language/expression/extractor.rb, which canonicalises what
/// Prism hands back - if these two disagree, the same predicate reaches the two
/// runtimes as two different strings.
pub fn canonicalise(source: &str) -> String {
    let collapsed = source.split_whitespace().collect::<Vec<_>>().join(" ");
    collapsed.replace(".length", ".size").trim().to_string()
}

/// `attribute :toppings, list_of(Topping)` -> ("Topping", true)
/// `attribute :name, String`               -> ("String", false)
pub fn attribute_type(line: &str) -> (String, bool) {
    let after_name = match line.find(',') {
        Some(index) => &line[index + 1..],
        None => return ("String".to_string(), false),
    };
    let text = after_name.split(',').next().unwrap_or("").trim();

    if let Some(inner) = text.strip_prefix("list_of(").and_then(|t| t.strip_suffix(')')) {
        return (inner.trim().to_string(), true);
    }
    (text.to_string(), false)
}

/// The `default:` on an attribute line, as a JSON value.
pub fn default_value(line: &str) -> Option<serde_json::Value> {
    let index = line.find("default:")?;
    let text = line[index + "default:".len()..].trim();

    if text.starts_with('"') {
        return quoted(text).map(serde_json::Value::String);
    }
    if let Ok(number) = text.trim_end_matches(',').parse::<i64>() {
        return Some(serde_json::Value::from(number));
    }
    match text {
        "true" => Some(serde_json::Value::Bool(true)),
        "false" => Some(serde_json::Value::Bool(false)),
        _ => None,
    }
}

/// The `{ name: :name, amount: :amount }` of an append mutation, as
/// value-object field -> command argument.
pub fn field_map(line: &str) -> Vec<(String, String)> {
    let open = match line.find('{') {
        Some(index) => index,
        None => return vec![],
    };
    let close = match line.rfind('}') {
        Some(index) => index,
        None => return vec![],
    };

    line[open + 1..close]
        .split(',')
        .filter_map(|pair| {
            let (field, argument) = pair.split_once(':')?;
            let argument = argument.trim().trim_start_matches(':').trim();
            if argument.is_empty() {
                return None;
            }
            Some((field.trim().to_string(), argument.to_string()))
        })
        .collect()
}
