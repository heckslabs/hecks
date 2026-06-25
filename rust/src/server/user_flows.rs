//! User flows reader — turns `<served-dir>/inbox/*.md` cards into JSON
//!
//! Each card under `inbox/` is a story : YAML frontmatter (ref, role,
//! value, status, priority, source, category, posted_at) followed by
//! a markdown body. The LivingDiagram's left sidebar fetches this list
//! at boot and renders a clickable nav of user flows. Click a card →
//! the diagram spotlights aggregates whose names appear in the card's
//! body or value (heuristic match) and opens the card detail in the
//! right panel.
//!
//! Future : a card can declare `dispatch_sequence:` in frontmatter
//! and the diagram plays that exact cascade through the runtime. For
//! now the panel surfaces the story + role-spotlight only.
//!
//! Usage :
//!   let json = user_flows::scan_inbox(served_dir);
//!
//! [antibody-exempt: rust/src/server/user_flows.rs — i527 LivingDiagram
//!  user-flows panel. Kernel-floor I/O reader for inbox card files.
//!  Retires when the runtime gains a hecksagon-declared :fs glob +
//!  yaml-frontmatter parser primitive (then this becomes the adapter
//!  implementation behind that declaration).]

use std::path::Path;

/// Read every `inbox/*.md` under `served_dir` and return them as a
/// JSON array of flow objects. Cards without YAML frontmatter are
/// included with empty fields ; bad files are silently skipped so a
/// single malformed card can't break the panel.
pub fn scan_inbox(served_dir: &Path) -> String {
    let inbox = served_dir.join("inbox");
    let entries = match std::fs::read_dir(&inbox) {
        Ok(e) => e,
        Err(_) => return "[]".to_string(),
    };

    let mut cards: Vec<Card> = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        let name = path.file_name().and_then(|s| s.to_str()).unwrap_or("").to_string();
        if !name.ends_with(".md") || name.starts_with('.') { continue; }
        let content = match std::fs::read_to_string(&path) {
            Ok(s) => s,
            Err(_) => continue,
        };
        if let Some(card) = parse_card(&name, &content) {
            cards.push(card);
        }
    }
    // Sort by ref using natural numeric order — i1, i2, i10, i100 not
    // i1, i10, i100, i2.
    cards.sort_by(|a, b| natural_ref_key(&a.reference)
        .cmp(&natural_ref_key(&b.reference)));

    let mut out = String::from("[");
    for (i, c) in cards.iter().enumerate() {
        if i > 0 { out.push(','); }
        out.push_str(&card_to_json(c));
    }
    out.push(']');
    out
}

/// One parsed inbox card.
struct Card {
    filename: String,
    reference: String,
    title: String,
    role: String,
    value: String,
    status: String,
    priority: String,
    category: String,
    source: String,
    body: String,
}

fn parse_card(filename: &str, content: &str) -> Option<Card> {
    let mut card = Card {
        filename: filename.to_string(),
        reference: filename.trim_end_matches(".md").to_string(),
        title: String::new(),
        role: String::new(),
        value: String::new(),
        status: String::new(),
        priority: String::new(),
        category: String::new(),
        source: String::new(),
        body: String::new(),
    };

    // Detect YAML frontmatter delimited by `---` lines at the head.
    let lines: Vec<&str> = content.lines().collect();
    let mut body_start = 0;
    if lines.first().map(|l| l.trim()) == Some("---") {
        let mut end_idx = None;
        for (i, line) in lines.iter().enumerate().skip(1) {
            if line.trim() == "---" { end_idx = Some(i); break; }
        }
        if let Some(end) = end_idx {
            for line in &lines[1..end] {
                if let Some(colon) = line.find(':') {
                    let key = line[..colon].trim();
                    let val = line[colon + 1..].trim()
                        .trim_matches('"').trim_matches('\'').to_string();
                    match key {
                        "ref"       => card.reference = val,
                        "role"      => card.role = val,
                        "value"     => card.value = val,
                        "status"    => card.status = val,
                        "priority"  => card.priority = val,
                        "category"  => card.category = val,
                        "source"    => card.source = val,
                        _ => {}
                    }
                }
            }
            body_start = end + 1;
        }
    }

    // Body : first H1 line becomes the title, the rest becomes body.
    let mut body_lines: Vec<&str> = Vec::new();
    for line in &lines[body_start..] {
        let t = line.trim();
        if card.title.is_empty() && t.starts_with("# ") {
            card.title = t[2..].trim().to_string();
            // Strip "i12 — " ref prefix to keep the title clean.
            if let Some(em) = card.title.find(" — ") {
                let prefix = &card.title[..em];
                if prefix.chars().all(|c| c.is_alphanumeric()) {
                    card.title = card.title[em + 5..].to_string();
                }
            }
        } else {
            body_lines.push(line);
        }
    }
    card.body = body_lines.join("\n").trim().to_string();
    if card.title.is_empty() {
        card.title = card.reference.clone();
    }

    Some(card)
}

/// Natural-sort key for refs like `i1`, `i12`, `i100`. Splits letters
/// from digits so numeric segments compare numerically.
fn natural_ref_key(s: &str) -> Vec<(String, u64)> {
    let mut out = Vec::new();
    let mut letters = String::new();
    let mut digits = String::new();
    for c in s.chars() {
        if c.is_ascii_digit() {
            if !letters.is_empty() {
                out.push((letters.clone(), 0));
                letters.clear();
            }
            digits.push(c);
        } else {
            if !digits.is_empty() {
                out.push((String::new(), digits.parse().unwrap_or(0)));
                digits.clear();
            }
            letters.push(c);
        }
    }
    if !letters.is_empty() { out.push((letters, 0)); }
    if !digits.is_empty() { out.push((String::new(), digits.parse().unwrap_or(0))); }
    out
}

fn card_to_json(c: &Card) -> String {
    format!(
        r#"{{"filename":{},"ref":{},"title":{},"role":{},"value":{},"status":{},"priority":{},"category":{},"source":{},"body":{}}}"#,
        json_str(&c.filename), json_str(&c.reference), json_str(&c.title),
        json_str(&c.role), json_str(&c.value), json_str(&c.status),
        json_str(&c.priority), json_str(&c.category), json_str(&c.source),
        json_str(&c.body),
    )
}

/// Minimal JSON string escaper — quote, backslash, control chars,
/// newlines. Matches the shape used elsewhere in server/.
fn json_str(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"'  => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => {
                out.push_str(&format!("\\u{:04x}", c as u32));
            }
            c => out.push(c),
        }
    }
    out.push('"');
    out
}
