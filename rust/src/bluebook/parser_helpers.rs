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

pub fn extract_kwarg_symbol(line: &str, kwarg: &str) -> Option<String> {
    let needle = format!("{kwarg}:");
    let start = line.find(&needle)? + needle.len();
    let rest = line[start..].trim_start();
    let rest = rest.strip_prefix(':')?;
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
    let required = line.contains("required:")
        && line
            .split("required:")
            .nth(1)
            .map(|a| a.trim_start().starts_with("true"))
            .unwrap_or(false);
    Some(crate::ir::Attribute {
        name,
        attr_type,
        default,
        list,
        required,
        enum_values: vec![],
        pattern: None,
        hint: None,
        logged: true,
    })
}

pub fn parse_shorthand_reference(line: &str) -> Option<crate::ir::Reference> {
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

    let domain = if target.contains("::") {
        Some(target.split("::").next()?.to_string())
    } else {
        None
    };

    Some(crate::ir::Reference::single(name, target, domain))
}

pub enum ShorthandResult {
    Attribute(crate::ir::Attribute),
    Reference(crate::ir::Reference),
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
