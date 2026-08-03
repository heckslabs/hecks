use crate::hecksagon_helpers::{between_quotes, strip_quotes};
use crate::world::ir::*;

pub fn is_world_source(source: &str) -> bool {
    for line in source.lines() {
        let t = line.trim();
        if t.is_empty() || t.starts_with('#') {
            continue;
        }
        return t.starts_with("Hecks.world");
    }
    false
}

const SCALAR_KEYS: &[&str] = &["purpose", "vision", "audience", "realm", "latest"];

pub fn parse(source: &str) -> World {
    let mut world = World::default();
    let source = crate::bluebook::parser_helpers::strip_shebang(source);
    let raw: Vec<&str> = source.lines().collect();

    let mut i = 0;
    while i < raw.len() {
        let line = raw[i].trim();

        if line.is_empty() || line.starts_with('#') {
            i += 1;
            continue;
        }

        if line.starts_with("Hecks.world") {
            if let Some(n) = between_quotes(line) {
                world.name = n;
            }
            i += 1;
            continue;
        }

        if let Some(k) = scalar_key(line) {
            if let Some(v) = between_quotes(line) {
                match k {
                    "purpose" => world.purpose = Some(v),
                    "vision" => world.vision = Some(v),
                    "audience" => world.audience = Some(v),
                    "realm" => world.realm = Some(v),
                    "latest" => world.latest = Some(v),
                    _ => {}
                }
            }
            i += 1;
            continue;
        }

        if line.starts_with("concern ") || line.starts_with("concern\"") {
            let (concern, consumed) = parse_concern(&raw[i..]);
            if let Some(c) = concern {
                world.concerns.push(c);
            }
            i += consumed;
            continue;
        }

        if line.starts_with("adapter \"") {
            let (binding, consumed) = parse_adapter_binding(&raw[i..]);
            if let Some(b) = binding {
                world.adapter_bindings.push(b);
            }
            i += consumed;
            continue;
        }

        if let Some(adapter_name) = verb_call_adapter(line) {
            let (cfg, consumed) = parse_verb_config_block(&raw[i..], &adapter_name);
            if let Some(c) = cfg {
                world.configs.push(c);
            }
            i += consumed;
            continue;
        }

        if let Some(ext_name) = extension_block_header(line) {
            let consumed = if ext_name == "mcp" {
                let (servers, n) = crate::world::parser_mcp::parse_mcp_block(&raw[i..]);
                world.servers.extend(servers);
                n
            } else {
                let (cfg, n) = parse_extension_block(&raw[i..], &ext_name);
                if let Some(c) = cfg {
                    world.configs.push(c);
                }
                n
            };
            i += consumed;
            continue;
        }

        i += 1;
    }

    world
}

fn scalar_key(line: &str) -> Option<&'static str> {
    for k in SCALAR_KEYS {
        if line.starts_with(&format!("{} ", k)) || line.starts_with(&format!("{}\"", k)) {
            return Some(*k);
        }
    }
    None
}

fn extension_block_header(line: &str) -> Option<String> {
    let t = line.trim();
    let rest = t;
    let ident_end = rest
        .find(|c: char| !c.is_alphanumeric() && c != '_')
        .unwrap_or(rest.len());
    if ident_end == 0 {
        return None;
    }
    let ident = &rest[..ident_end];
    if SCALAR_KEYS.contains(&ident) || ident == "concern" || ident == "end" || ident == "Hecks" {
        return None;
    }
    let after = rest[ident_end..].trim_start();
    if after == "do" || after.starts_with("do ") || after.starts_with("do;") || after == "do\n" {
        return Some(ident.to_string());
    }
    if after.starts_with("do") {
        let next = after.chars().nth(2);
        if next.is_none_or(|c| c.is_whitespace() || c == ';') {
            return Some(ident.to_string());
        }
    }
    None
}

fn parse_adapter_binding(lines: &[&str]) -> (Option<AdapterBinding>, usize) {
    let first = lines[0].trim();
    let mut binding = AdapterBinding::default();
    if let Some(n) = between_quotes(first) {
        binding.name = n;
    }

    if first.ends_with("end") && first.contains("do") {
        absorb_inline_block_body(first, &mut |k, v| {
            binding.values.push((k, v));
        });
        return (
            if binding.name.is_empty() {
                None
            } else {
                Some(binding)
            },
            1,
        );
    }

    let mut i = 1;
    let mut depth = if ends_with_do(first) { 1 } else { 0 };
    while i < lines.len() && depth > 0 {
        let t = lines[i].trim();
        if t == "end" {
            depth -= 1;
            i += 1;
            continue;
        }
        if t.is_empty() || t.starts_with('#') {
            i += 1;
            continue;
        }
        if ends_with_do(t) {
            depth += 1;
            i += 1;
            continue;
        }
        if let Some((k, v)) = parse_kv_line(t) {
            binding.values.push((k, v));
        }
        i += 1;
    }
    (
        if binding.name.is_empty() {
            None
        } else {
            Some(binding)
        },
        i,
    )
}

fn parse_concern(lines: &[&str]) -> (Option<Concern>, usize) {
    let first = lines[0].trim();
    let mut concern = Concern::default();
    if let Some(n) = between_quotes(first) {
        concern.name = n;
    }

    if first.ends_with("end") && first.contains("do") {
        absorb_inline_block_body(first, &mut |k, v| {
            if k == "description" {
                concern.description = Some(v);
            }
        });
        return (
            if concern.name.is_empty() {
                None
            } else {
                Some(concern)
            },
            1,
        );
    }

    let mut i = 1;
    let mut depth = if first.trim_end().ends_with("do") {
        1
    } else {
        0
    };
    while i < lines.len() && depth > 0 {
        let t = lines[i].trim();
        if t == "end" {
            depth -= 1;
            i += 1;
            continue;
        }
        if t.is_empty() || t.starts_with('#') {
            i += 1;
            continue;
        }
        if ends_with_do(t) {
            depth += 1;
        }
        if let Some((k, v)) = parse_kv_line(t) {
            if k == "description" {
                concern.description = Some(v);
            }
        }
        i += 1;
    }

    if concern.name.is_empty() {
        (None, i)
    } else {
        (Some(concern), i)
    }
}

fn parse_extension_block(lines: &[&str], name: &str) -> (Option<ExtensionConfig>, usize) {
    let first = lines[0].trim();
    let mut cfg = ExtensionConfig {
        name: name.to_string(),
        values: vec![],
    };

    if first.ends_with("end") && first.contains("do") {
        absorb_inline_block_body(first, &mut |k, v| {
            cfg.values.push((k, v));
        });
        return (Some(cfg), 1);
    }

    let mut i = 1;
    let mut depth = if ends_with_do(first) { 1 } else { 0 };
    while i < lines.len() && depth > 0 {
        let t = lines[i].trim();
        if t == "end" {
            depth -= 1;
            i += 1;
            continue;
        }
        if t.is_empty() || t.starts_with('#') {
            i += 1;
            continue;
        }
        if ends_with_do(t) {
            depth += 1;
            i += 1;
            continue;
        }
        if let Some((k, v)) = parse_kv_line(t) {
            cfg.values.push((k, v));
        }
        i += 1;
    }

    (Some(cfg), i)
}

pub(crate) fn ends_with_do(line: &str) -> bool {
    let t = line.trim_end();
    t == "do" || t.ends_with(" do")
}

fn verb_call_adapter(line: &str) -> Option<String> {
    let t = line.trim();
    let is_block = ends_with_do(t) || (t.contains(" do") && t.ends_with("end"));
    if !is_block {
        return None;
    }
    let open = t.find("(\"")?;
    let before = &t[..open];
    if before.is_empty() || !before.ends_with(|c: char| c.is_alphanumeric() || c == '_') {
        return None;
    }
    let after = &t[open + 2..];
    let close = after.find('"')?;
    let adapter = &after[..close];
    if adapter.is_empty() {
        return None;
    }
    Some(adapter.to_lowercase())
}

fn parse_verb_config_block(lines: &[&str], name: &str) -> (Option<ExtensionConfig>, usize) {
    let first = lines[0].trim();
    let mut cfg = ExtensionConfig {
        name: name.to_string(),
        ..Default::default()
    };

    if first.ends_with("end") && first.contains("do") {
        absorb_inline_block_body(first, &mut |k, v| cfg.values.push((k, v)));
        return (Some(cfg), 1);
    }

    let mut i = 1;
    let mut depth = if ends_with_do(first) { 1 } else { 0 };
    while i < lines.len() && depth > 0 {
        let t = lines[i].trim();
        if t == "end" {
            depth -= 1;
            i += 1;
            continue;
        }
        if t.is_empty() || t.starts_with('#') {
            i += 1;
            continue;
        }
        if ends_with_do(t) {
            depth += 1;
            i += 1;
            continue;
        }
        if let Some((k, v)) = parse_kv_line(t) {
            cfg.values.push((k, v));
        }
        i += 1;
    }
    (Some(cfg), i)
}

pub(crate) fn parse_kv_line(line: &str) -> Option<(String, String)> {
    let t = line.trim().trim_end_matches(';');
    let ident_end = t.find(|c: char| !c.is_alphanumeric() && c != '_')?;
    if ident_end == 0 {
        return None;
    }
    let key = t[..ident_end].to_string();
    let rest = t[ident_end..].trim();
    if rest.is_empty() {
        return None;
    }
    Some((key, render_value(rest)))
}

fn render_value(raw: &str) -> String {
    let t = raw.trim().trim_end_matches(';').trim();
    if is_single_quoted_string(t) {
        return strip_quotes(t);
    }
    if let Some(sym) = t.strip_prefix(':') {
        if !sym.is_empty() && sym.chars().all(|c| c.is_alphanumeric() || c == '_') {
            return sym.to_string();
        }
    }
    t.to_string()
}

fn is_single_quoted_string(t: &str) -> bool {
    if !(t.starts_with('"') && t.ends_with('"') && t.len() >= 2) {
        return false;
    }
    let bytes = t.as_bytes();
    let mut prev = b'\0';
    for &b in &bytes[1..bytes.len() - 1] {
        if b == b'"' && prev != b'\\' {
            return false;
        }
        prev = b;
    }
    true
}

pub(crate) fn absorb_inline_block_body(line: &str, visitor: &mut dyn FnMut(String, String)) {
    let t = line.trim();
    let Some(after_do_idx) = find_do_keyword(t) else {
        return;
    };
    let after_do = &t[after_do_idx..];
    let body = after_do
        .trim_start()
        .trim_start_matches("do")
        .trim_start_matches(|c: char| c == ';' || c.is_whitespace());
    let body = body.trim_end().trim_end_matches("end").trim();
    for piece in body.split(';') {
        let p = piece.trim();
        if p.is_empty() {
            continue;
        }
        if let Some((k, v)) = parse_kv_line(p) {
            visitor(k, v);
        }
    }
}

fn find_do_keyword(line: &str) -> Option<usize> {
    let bytes = line.as_bytes();
    let mut i = 0;
    while i + 2 <= bytes.len() {
        if &bytes[i..i + 2] == b"do" {
            let left_ok = i == 0 || (bytes[i - 1] as char).is_whitespace();
            let right_ok = i + 2 == bytes.len() || {
                let c = bytes[i + 2] as char;
                c.is_whitespace() || c == ';'
            };
            if left_ok && right_ok {
                return Some(i);
            }
        }
        i += 1;
    }
    None
}
