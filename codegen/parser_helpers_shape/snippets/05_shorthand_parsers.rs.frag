/// Detect shorthand attribute or reference lines.
pub fn is_shorthand_line(line: &str) -> bool {
    SHORTHAND_TYPES.iter().any(|t| {
        line.starts_with(t) && line[t.len()..].starts_with(|c: char| c == ' ' || c == '\t')
    }) || line.starts_with("list_of(")
       || line.starts_with("reference_to(")
}

/// Detect bare PascalCase command: `CreatePizza do` or `CreatePizza {`.
pub fn is_shorthand_command(line: &str) -> bool {
    let first_word = line.split_whitespace().next().unwrap_or("");
    if first_word.len() < 2 { return false; }
    let chars: Vec<char> = first_word.chars().collect();
    let is_pascal = chars[0].is_uppercase() && chars[1..].iter().any(|c| c.is_lowercase());
    is_pascal
        && (line.ends_with(" do") || line.contains('{'))
        && !KEYWORDS.iter().any(|k| first_word == *k)
}

/// Parse `String :name`, `Integer :count`, `list_of(Order) :tags`,
/// and the `default:` kwarg form `Integer :count, default: 0`.
pub fn parse_shorthand_attribute(line: &str) -> Option<crate::ir::Attribute> {
    let list = line.starts_with("list_of(");
    let attr_type = if list {
        let open = line.find('(')? + 1;
        let close = line.find(')')?;
        line[open..close].trim().to_string()
    } else {
        let end = line.find(|c: char| c == ' ' || c == '\t')?;
        line[..end].to_string()
    };
    let name = extract_symbol(line)?;
    let default = if line.contains("default:") {
        let pos = line.find("default:")?;
        let after = line[pos + "default:".len()..].trim();
        if after.starts_with('"') {
            // Quoted string default — strip quotes.
            let end = after[1..].find('"').map(|i| i + 1)?;
            Some(after[1..end].to_string())
        } else {
            // Bare token default (number, true, false, identifier).
            let token = after.split(|c: char| c == ',' || c.is_whitespace())
                .next().unwrap_or("").to_string();
            if token.is_empty() { None } else { Some(token) }
        }
    } else { None };
    let required = line.contains("required:")
        && line.split("required:").nth(1).map(|a| a.trim_start().starts_with("true")).unwrap_or(false);
    Some(crate::ir::Attribute { name, attr_type, default, list, required })
}

/// Parse a reference declaration in any of these forms:
///
///   reference_to(Order)                            — name = `order` (snake target)
///   reference_to(Order, as: :recent_purchase)      — canonical alias kwarg
///   reference_to(Order, role: :recent_purchase)    — legacy kwarg, still accepted
///   reference_to(Order).as(:recent_purchase)       — Rust-style suffix
///   reference_to(Order) :recent_purchase           — trailing-symbol shorthand
///
/// All five resolve to the same Reference IR. Canonical going forward
/// is `as:`; the others remain accepted so existing bluebooks keep
/// parsing while authors migrate.
pub fn parse_shorthand_reference(line: &str) -> Option<crate::ir::Reference> {
    let open = line.find('(')? + 1;
    let close = line.find(')')?;
    let inside = &line[open..close];
    let after_close = &line[close + 1..];
    // Target is the first identifier inside the parens (before any comma).
    let target = inside.split(',').next()?.trim().to_string();

    let name = if line.contains(".as(") {
        // `.as(:foo)` Rust-style suffix.
        let as_pos = line.find(".as(")?;
        extract_symbol(&line[as_pos..]).unwrap_or_else(|| to_snake_case(&target))
    } else if let Some(pos) = inside.find(", as:") {
        // `, as: :foo` — canonical kwarg.
        let after = &inside[pos + ", as:".len()..];
        extract_symbol(after).unwrap_or_else(|| to_snake_case(&target))
    } else if let Some(pos) = inside.find("as:") {
        // `as: :foo` — also accepted (no leading comma).
        let after = &inside[pos + "as:".len()..];
        extract_symbol(after).unwrap_or_else(|| to_snake_case(&target))
    } else if let Some(role_pos) = inside.find("role:") {
        // `role: :foo` — legacy, kept for back-compat.
        let after_kwarg = &inside[role_pos + "role:".len()..];
        extract_symbol(after_kwarg).unwrap_or_else(|| to_snake_case(&target))
    } else if after_close.trim_start().starts_with(':') {
        // `reference_to(Order) :foo` — trailing-symbol shorthand
        // (mirrors `String :name` style on attributes).
        extract_symbol(after_close).unwrap_or_else(|| to_snake_case(&target))
    } else {
        to_snake_case(&target)
    };

    let domain = if target.contains("::") {
        Some(target.split("::").next()?.to_string())
    } else {
        None
    };

    // Reference gained `cardinality` and `kind` fields; the shorthand
    // parser routes through Reference::single (LegacyReferenceTo,
    // single cardinality) so the construction stays valid as the
    // struct grows.
    Some(crate::ir::Reference::single(name, target, domain))
}

/// Unified shorthand dispatcher — keeps call sites to a 3-line match.
pub enum ShorthandResult {
    Attribute(crate::ir::Attribute),
    Reference(crate::ir::Reference),
    None,
}

pub fn parse_shorthand(line: &str) -> ShorthandResult {
    if !is_shorthand_line(line) { return ShorthandResult::None; }
    if line.starts_with("reference_to(") {
        parse_shorthand_reference(line)
            .map(ShorthandResult::Reference)
            .unwrap_or(ShorthandResult::None)
    } else {
        parse_shorthand_attribute(line)
            .map(ShorthandResult::Attribute)
            .unwrap_or(ShorthandResult::None)
    }
}
