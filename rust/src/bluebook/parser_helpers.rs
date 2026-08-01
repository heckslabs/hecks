pub fn extract_string(line: &str) -> Option<String> {
    let start = line.find('"')? + 1;
    let mut out = String::new();
    let mut chars = line[start..].chars();
    while let Some(c) = chars.next() {
        if c == '\\' {
            match chars.next() {
                Some('"') => out.push('"'),
                Some('\\') => out.push('\\'),
                Some('n') => out.push('\n'),
                Some('t') => out.push('\t'),
                Some('r') => out.push('\r'),
                Some('0') => out.push('\0'),
                Some(other) => out.push(other),
                None => return None,
            }
            continue;
        }
        if c == '"' {
            return Some(out);
        }
        out.push(c);
    }
    None
}

pub fn extract_kwarg_string(line: &str, keyword: &str) -> Option<String> {
    let marker = format!("{}:", keyword);
    let idx = line.find(&marker)?;
    extract_string(&line[idx + marker.len()..])
}

pub fn extract_string_spanning(lines: &[&str], start: usize) -> (Option<String>, usize) {
    let first = lines[start];
    let open = match first.find('"') {
        Some(p) => p + 1,
        None => return (None, 1),
    };
    let mut out = String::new();
    let mut idx = start;
    let mut segment = &first[open..];
    loop {
        let mut chars = segment.chars();
        let mut closed = false;
        while let Some(c) = chars.next() {
            if c == '\\' {
                match chars.next() {
                    Some('"') => out.push('"'),
                    Some('\\') => out.push('\\'),
                    Some('n') => out.push('\n'),
                    Some('t') => out.push('\t'),
                    Some('r') => out.push('\r'),
                    Some('0') => out.push('\0'),
                    Some(other) => out.push(other),
                    None => break,
                }
                continue;
            }
            if c == '"' {
                closed = true;
                break;
            }
            out.push(c);
        }
        let consumed = idx - start + 1;
        if closed {
            return (Some(out), consumed);
        }
        idx += 1;
        if idx >= lines.len() {
            return (None, consumed);
        }
        out.push('\n');
        segment = lines[idx];
    }
}

pub fn strip_trailing_comment(line: &str) -> &str {
    let mut in_str = false;
    let mut prev = '\0';
    for (idx, c) in line.char_indices() {
        match c {
            '"' if prev != '\\' => in_str = !in_str,
            '#' if !in_str => return line[..idx].trim_end(),
            _ => {}
        }
        prev = c;
    }
    line
}

pub fn extract_second_string(line: &str) -> Option<String> {
    let first_open = line.find('"')? + 1;
    let mut idx = first_open;
    let bytes = line.as_bytes();
    while idx < bytes.len() {
        let b = bytes[idx];
        if b == b'\\' && idx + 1 < bytes.len() {
            idx += 2;
            continue;
        }
        if b == b'"' {
            idx += 1;
            break;
        }
        idx += 1;
    }
    let second_open_offset = line[idx..].find('"')?;
    let second_open = idx + second_open_offset + 1;
    let mut out = String::new();
    let mut chars = line[second_open..].chars();
    while let Some(c) = chars.next() {
        if c == '\\' {
            match chars.next() {
                Some('"') => out.push('"'),
                Some('\\') => out.push('\\'),
                Some('n') => out.push('\n'),
                Some('t') => out.push('\t'),
                Some('r') => out.push('\r'),
                Some('0') => out.push('\0'),
                Some(other) => out.push(other),
                None => return None,
            }
            continue;
        }
        if c == '"' {
            return Some(out);
        }
        out.push(c);
    }
    None
}

pub fn extract_symbol(line: &str) -> Option<String> {
    let start = line.find(':')? + 1;
    let rest = &line[start..];
    let end = rest
        .find(|c: char| !c.is_alphanumeric() && c != '_')
        .unwrap_or(rest.len());
    let sym = rest[..end].trim().to_string();
    if sym.is_empty() {
        None
    } else {
        Some(sym)
    }
}

/// THE PATHS A CONSTRUCT IS KNOWN BY, in declaration order, read in ONE place.
///
/// Three spellings and ONE rule. Ruby never CALLS the block — it reads the
/// source, collapses the whitespace and splits on spaces
/// (`AggregateBuilder#identified_by`) — so the paths are simply the words the
/// block holds:
///
///   identified_by :sequence            a symbol names the attribute
///   identified_by { number.value }      one path, inline
///   identified_by do … end              several paths, one to a line
///
/// A head and a piece spell this identically, so they must READ it identically.
///
/// THE BLOCK FORM WAS UNREADABLE HERE, and not by half — `do` opened a block the
/// aggregate parser never consumed, so everything to the matching `end` was
/// swallowed and the construct came back with no attributes, no commands and no
/// value objects. Silent, because an empty aggregate does not look like a parse
/// failure, and unreachable from the parity corpus because every example was
/// identified by one path. The language's OWN chapters are composite throughout,
/// and the meta-domain is the one bluebook Rust never parses.
///
/// `lines[0]` is the `identified_by` line. The count returned is every line
/// consumed including that one — `parse_lifecycle`'s convention — so a caller
/// advances by it and continues, whichever spelling it met.
pub fn extract_identity_paths(lines: &[&str]) -> (Vec<String>, usize) {
    let first = lines[0].trim();

    if first.contains(char::from(123)) {
        let inner = first
            .split(char::from(123))
            .nth(1)
            .and_then(|inner| inner.split(char::from(125)).next())
            .unwrap_or_default();
        return (identity_words(inner), 1);
    }

    if !ends_with_do_block(first) {
        return (extract_symbol(first).into_iter().collect(), 1);
    }

    let mut paths = vec![];
    let mut consumed = 1;
    while consumed < lines.len() {
        let line = lines[consumed].trim();
        consumed += 1;
        if line == "end" {
            break;
        }
        // Ruby's extractor hands back the block's source with its comments
        // already gone, so a comment is not a path — and one that survived
        // would arrive as words and be declared as identity parts.
        if line.starts_with('#') {
            continue;
        }
        paths.extend(identity_words(line));
    }
    (paths, consumed)
}

/// Whitespace collapsed, split on spaces — the shape Ruby's canonical form
/// leaves the block's source in. One line may carry several paths for the same
/// reason the block may: they are words either way.
fn identity_words(text: &str) -> Vec<String> {
    text.split_whitespace().map(str::to_string).collect()
}

pub fn extract_word_after(line: &str, keyword: &str) -> Option<String> {
    let start = line.find(keyword)? + keyword.len();
    let rest = line[start..].trim();
    let end = rest
        .find(|c: char| !c.is_alphanumeric() && c != '_' && c != ':')
        .unwrap_or(rest.len());
    let word = rest[..end].trim().to_string();
    if word.is_empty() {
        None
    } else {
        Some(word)
    }
}

pub fn extract_block(line: &str) -> Option<String> {
    let start = line.find('{')? + 1;
    let end = line.rfind('}')?;
    Some(line[start..end].trim().to_string())
}

pub fn extract_after(line: &str, keyword: &str) -> Option<String> {
    let start = line.find(keyword)? + keyword.len();
    let rest = line[start..].trim();
    Some(rest.trim_end_matches([',', ' ']).to_string())
}

pub fn extract_state_token(text: &str) -> Option<String> {
    let t = text.trim_start();
    if t.starts_with('"') {
        return extract_string(t);
    }
    let body = t.strip_prefix(':').unwrap_or(t);
    let end = body
        .find(|c: char| !c.is_alphanumeric() && c != '_')
        .unwrap_or(body.len());
    let tok = body[..end].trim().to_string();
    if tok.is_empty() {
        None
    } else {
        Some(tok)
    }
}

pub fn ends_with_do_block(line: &str) -> bool {
    let trimmed = line.trim();
    if trimmed.starts_with('#') {
        return false;
    }
    if trimmed.ends_with(" do") || trimmed == "do" {
        return true;
    }
    if let Some(without_bar) = trimmed.strip_suffix('|') {
        if let Some(open) = without_bar.rfind('|') {
            let head = trimmed[..open].trim_end();
            return head.ends_with(" do") || head == "do";
        }
    }
    false
}

const SHORTHAND_TYPES: &[&str] = &[
    "String", "Integer", "Float", "Boolean", "JSON", "Date", "DateTime",
];

const KEYWORDS: &[&str] = &[
    "aggregate",
    "policy",
    "lifecycle",
    "value_object",
    "vow",
    "fixture",
    "category",
    "vision",
    "description",
    "Hecks",
    "String",
    "Integer",
    "Float",
    "Boolean",
    "JSON",
    "Date",
    "DateTime",
];

pub fn is_shorthand_line(line: &str) -> bool {
    SHORTHAND_TYPES
        .iter()
        .any(|t| line.starts_with(t) && line[t.len()..].starts_with([' ', '\t']))
        || line.starts_with("list_of(")
        || line.starts_with("reference_to(")
}

pub fn is_shorthand_command(line: &str) -> bool {
    let first_word = line.split_whitespace().next().unwrap_or("");
    if first_word.len() < 2 {
        return false;
    }
    let chars: Vec<char> = first_word.chars().collect();
    let is_pascal = chars[0].is_uppercase() && chars[1..].iter().any(|c| c.is_lowercase());
    is_pascal && (line.ends_with(" do") || line.contains('{')) && !KEYWORDS.contains(&first_word)
}

pub fn parse_shorthand_attribute(line: &str) -> Option<crate::ir::Attribute> {
    let list = line.starts_with("list_of(");
    let attr_type = if list {
        let open = line.find('(')? + 1;
        let close = line.find(')')?;
        line[open..close].trim().to_string()
    } else {
        let end = line.find([' ', '\t'])?;
        line[..end].to_string()
    };
    let name = extract_symbol(line)?;
    let default = if line.contains("default:") {
        let pos = line.find("default:")?;
        let after = line[pos + "default:".len()..].trim();
        if let Some(rest) = after.strip_prefix('"') {
            let end = rest.find('"')?;
            Some(rest[..end].to_string())
        } else {
            let token = after
                .split(|c: char| c == ',' || c.is_whitespace())
                .next()
                .unwrap_or("")
                .to_string();
            if token.is_empty() {
                None
            } else {
                Some(token)
            }
        }
    } else {
        None
    };
    let optional = line.contains("optional:")
        && line
            .split("optional:")
            .nth(1)
            .map(|a| a.trim_start().starts_with("true"))
            .unwrap_or(false);
    Some(crate::ir::Attribute {
        name,
        r#type: attr_type,
        default,
        list,
        optional,
        enum_values: vec![],
        pattern: None,
        // READ HERE TOO, unlike `pattern` beside it. `admits` is a RULE, and a
        // rule the long spelling enforces and the shorthand quietly drops is the
        // same bluebook meaning two things — which is the whole reason this fact
        // crosses the wire at all.
        admits: super::parse_blocks::parse_quoted_kwarg(line, "admits:"),
    })
}

/// A REFERENCE IS AN ATTRIBUTE — `Reference<Customer>` is a type, not a second
/// kind of declaration. Ruby's builder reaches this through the shared
/// attribute collector, so the two sides carry one shape and not two.
pub fn reference_attribute(name: String, target: &str) -> crate::ir::Attribute {
    crate::ir::Attribute {
        name,
        r#type: format!("Reference<{target}>"),
        default: None,
        list: false,
        // A reference is an ID, never defaulted, never pattern-matched and
        // never a member of a closed set — but it travels the same collector as
        // every other attribute, so it carries the same keys.
        optional: false,
        enum_values: vec![],
        pattern: None,
        admits: None,
    }
}

/// What a reference-typed attribute POINTS AT, or none if it points at nothing.
pub fn reference_target(attribute: &crate::ir::Attribute) -> Option<&str> {
    attribute
        .r#type
        .strip_prefix("Reference<")?
        .strip_suffix('>')
}

/// Is this reference the ROOT the command acts on, or a named argument?
///
/// `as:` means "a named argument", not "the root I act on" — so a command can
/// point at another instance of its OWN kind, which is what
/// `reference_to Aggregate, as: :points_at` says in the meta-domain. Mirrors
/// CommandBuilder#reference_to: without this, Rust drops such a reference from
/// the attributes AND claims it as the acted-on root, and the two runtimes
/// disagree about the same line.
///
/// Explicitness is inferred by comparing against the derived name. When `as:`
/// names exactly what the default would have produced, the two readings
/// coincide anyway.
pub fn acts_on_root(attribute: &crate::ir::Attribute, owner: &str) -> bool {
    match reference_target(attribute) {
        Some(target) => {
            target == owner && attribute.name == format!("{}_id", crate::naming::snake(target))
        }
        None => false,
    }
}

pub fn parse_shorthand_reference(line: &str) -> Option<crate::ir::Attribute> {
    let open = line.find('(')? + 1;
    let close = line.find(')')?;
    let inside = &line[open..close];
    let after_close = &line[close + 1..];
    let target = inside.split(',').next()?.trim().to_string();

    let name = if line.contains(".as(") {
        let as_pos = line.find(".as(")?;
        extract_symbol(&line[as_pos..]).unwrap_or_else(|| crate::naming::snake(&target))
    } else if let Some(pos) = inside.find(", as:") {
        let after = &inside[pos + ", as:".len()..];
        extract_symbol(after).unwrap_or_else(|| crate::naming::snake(&target))
    } else if let Some(pos) = inside.find("as:") {
        let after = &inside[pos + "as:".len()..];
        extract_symbol(after).unwrap_or_else(|| crate::naming::snake(&target))
    } else if let Some(role_pos) = inside.find("role:") {
        let after_kwarg = &inside[role_pos + "role:".len()..];
        extract_symbol(after_kwarg).unwrap_or_else(|| crate::naming::snake(&target))
    } else if after_close.trim_start().starts_with(':') {
        extract_symbol(after_close).unwrap_or_else(|| crate::naming::snake(&target))
    } else {
        crate::naming::snake(&target)
    };

    Some(reference_attribute(name, &target))
}

pub enum ShorthandResult {
    Attribute(crate::ir::Attribute),
    /// Still told apart from a plain attribute, because a reference is
    /// PREPENDED to the attribute list rather than appended — see
    /// `parser::parse_aggregate`.
    Reference(crate::ir::Attribute),
    None,
}

pub fn parse_shorthand(line: &str) -> ShorthandResult {
    if !is_shorthand_line(line) {
        return ShorthandResult::None;
    }
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
