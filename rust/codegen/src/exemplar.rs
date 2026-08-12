//! Port of `rust/project/exemplar.rb`'s `Exemplar` module — same source
//! tree (`rust/src/exemplar/*.rs`), same `// TMPL:<id> BEGIN`/`END`
//! fencing, same substitution rules. Read `exemplar.rb` in full before
//! touching this file; every method here has a named Ruby counterpart and
//! this port follows its algorithm and comments directly rather than
//! reinventing the mechanism.
//!
//! Deliberately NOT sharing code with `exemplar.rb` (impossible — cross-
//! language) but sharing the SAME DATA (`rust/src/exemplar/*.rs`, read at
//! runtime by both, never duplicated into this crate) — the one thing
//! that actually needs to stay in sync between the two codegens is which
//! literal shapes exist and what they say, and that's a file both read,
//! not a fact either encodes independently.
use std::collections::HashMap;
use std::path::PathBuf;

pub struct Exemplar {
    shapes: HashMap<String, String>,
}

/// Any marker this vocabulary can produce — see `exemplar.rb`'s own
/// `LEFTOVER_PLACEHOLDER` header for the full rationale (covers both
/// identifier-shaped and literal-content placeholders in one check).
fn is_leftover_placeholder(word: &str) -> bool {
    (word.starts_with("Tmpl") && word.len() > 4)
        || (word.starts_with("tmpl_") && word.len() > 5)
        || (word.starts_with("TMPL_") && word.len() > 5)
}

/// Scan `text` for `\b(?:Tmpl\w*|tmpl_\w*|TMPL_\w*)\b`-shaped leftovers —
/// a small hand-rolled word scanner standing in for the Ruby regex, since
/// this crate carries no regex dependency (same zero-dependency discipline
/// `rust/parser` already holds itself to).
fn scan_leftover_placeholders(text: &str) -> Vec<String> {
    // Byte-index candidate positions, but only ones that fall on real char
    // boundaries — generated text embeds real corpus prose (invariant
    // descriptions, `vision` strings, ...) that can contain multi-byte
    // UTF-8 characters (an em dash, `—`), and a raw byte-by-byte walk that
    // slices `&text[i..]` at an arbitrary `i` panics the moment `i` lands
    // inside one of those characters' continuation bytes — found live,
    // running this against the self-hosted grammar chapter (whose own
    // `RefusalTemplate` members embed literal `—` characters).
    let mut found = Vec::new();
    let bytes = text.as_bytes();
    let is_word_byte = |b: u8| b.is_ascii_alphanumeric() || b == b'_';
    let mut i = 0;
    while i < bytes.len() {
        if !text.is_char_boundary(i) {
            i += 1;
            continue;
        }
        let at_boundary = i == 0 || !is_word_byte(bytes[i - 1]);
        if at_boundary {
            let rest = &text[i..];
            if rest.starts_with("Tmpl") || rest.starts_with("tmpl_") || rest.starts_with("TMPL_") {
                let start = i;
                let mut j = i;
                while j < bytes.len() && is_word_byte(bytes[j]) {
                    j += 1;
                }
                let word = &text[start..j];
                if is_leftover_placeholder(word) && !found.iter().any(|w| w == word) {
                    found.push(word.to_string());
                }
                i = j;
                continue;
            }
        }
        i += 1;
    }
    found
}

impl Exemplar {
    pub fn load() -> Self {
        Self::load_from(default_dir())
    }

    pub fn load_from(dir: PathBuf) -> Self {
        let mut shapes = HashMap::new();
        let mut paths: Vec<_> = std::fs::read_dir(&dir)
            .unwrap_or_else(|e| panic!("Exemplar: cannot read {}: {e}", dir.display()))
            .filter_map(|entry| entry.ok())
            .map(|entry| entry.path())
            .filter(|p| p.extension().map(|ext| ext == "rs").unwrap_or(false))
            .collect();
        paths.sort();
        for path in paths {
            let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("Exemplar: cannot read {}: {e}", path.display()));
            parse_file(&path, &text, &mut shapes);
        }
        Self { shapes }
    }

    pub fn raw(&self, shape_id: &str) -> &str {
        self.shapes
            .get(shape_id)
            .unwrap_or_else(|| panic!("Exemplar: no shape {shape_id:?} — checked rust/src/exemplar/*.rs for `// TMPL:{shape_id} BEGIN`"))
    }

    /// Fixed-arity rendering — mirrors `exemplar.rb#render` exactly,
    /// including the longest-marker-first ordering and the leftover-
    /// placeholder check both ways.
    pub fn render(&self, shape_id: &str, subs: &[(&str, String)]) -> String {
        let mut text = self.raw(shape_id).to_string();
        render_subs(shape_id, "render", &mut text, subs);
        text
    }

    pub fn render_each(&self, shape_id: &str, subs_list: &[Vec<(&str, String)>], join_with: &str) -> String {
        subs_list.iter().map(|subs| self.render(shape_id, subs)).collect::<Vec<_>>().join(join_with)
    }

    /// General splice — mirrors `exemplar.rb#assemble`: nested slots
    /// filled (each reindented by its OWN marker's position) BEFORE the
    /// outer substitutions run, so an outer marker can never accidentally
    /// match text that came from an already-rendered slot.
    pub fn assemble(&self, outer_id: &str, outer_subs: &[(&str, String)], slots: &[(&str, String)]) -> String {
        let mut outer_text = self.raw(outer_id).to_string();

        for (field_id, content) in slots {
            let slot = format!("<<TMPL_SLOT:{field_id}>>");
            let (line_start, line_end, indent) = find_slot_line(&outer_text, &slot).unwrap_or_else(|| {
                panic!(
                    "Exemplar.assemble({outer_id:?}): no nested slot for {field_id:?} — expected a `// TMPL:{field_id} BEGIN/END` region nested inside `// TMPL:{outer_id} BEGIN/END`"
                )
            });
            let reindented: String = content
                .lines()
                .map(|l| if l.trim().is_empty() { l.to_string() } else { format!("{indent}{l}") })
                .collect::<Vec<_>>()
                .join("\n");
            outer_text = format!("{}{}{}", &outer_text[..line_start], reindented, &outer_text[line_end..]);
        }

        render_subs(outer_id, "assemble", &mut outer_text, outer_subs);
        outer_text
    }

    /// Two-level composition for the common single-slot case — mirrors
    /// `exemplar.rb#compose`.
    pub fn compose(&self, outer_id: &str, outer_subs: &[(&str, String)], field_id: &str, field_subs_list: &[Vec<(&str, String)>], join_with: &str) -> String {
        let content = self.render_each(field_id, field_subs_list, join_with);
        self.assemble(outer_id, outer_subs, &[(field_id, content)])
    }
}

/// Longest-marker-first substitution, then the leftover-placeholder scan
/// both directions — the shared tail of `render`/`assemble` (`exemplar.rb`
/// keeps this duplicated across its own two methods too, for the same
/// reason: no shared private helper existed for it in the original either,
/// and this mirrors that rather than "improving" on it during the port).
fn render_subs(shape_id: &str, caller: &str, text: &mut String, subs: &[(&str, String)]) {
    let mut ordered: Vec<&(&str, String)> = subs.iter().collect();
    ordered.sort_by_key(|(marker, _)| std::cmp::Reverse(marker.len()));

    for (marker, value) in ordered {
        if !text.contains(marker) {
            panic!("Exemplar.{caller}({shape_id:?}): marker {marker:?} not found in shape text — exemplar and caller have drifted");
        }
        *text = text.replace(marker, value);
    }

    let leftover = scan_leftover_placeholders(text);
    if !leftover.is_empty() {
        panic!("Exemplar.{caller}({shape_id:?}): unrendered placeholder(s) {leftover:?} — subs is missing a marker this shape actually contains");
    }
}

/// Finds the full line (including trailing newline, if any) containing
/// `<<TMPL_SLOT:id>>` at some indentation, returning `(byte_start,
/// byte_end, indent)` — mirrors `exemplar.rb`'s own regex `^([
/// \t]*)#{Regexp.escape(slot)}$` applied per-line.
fn find_slot_line(text: &str, slot: &str) -> Option<(usize, usize, String)> {
    let mut offset = 0usize;
    for line in text.split_inclusive('\n') {
        let trimmed_end = line.trim_end_matches('\n').trim_end_matches('\r');
        if let Some(rest) = trimmed_end.strip_suffix(slot) {
            if rest.chars().all(|c| c == ' ' || c == '\t') {
                let line_len = trimmed_end.len();
                return Some((offset, offset + line_len, rest.to_string()));
            }
        }
        offset += line.len();
    }
    None
}

fn default_dir() -> PathBuf {
    PathBuf::from(concat!(env!("CARGO_MANIFEST_DIR"), "/../src/exemplar"))
}

fn begin_marker(line: &str) -> Option<&str> {
    marker_id(line, "BEGIN")
}

fn end_marker(line: &str) -> Option<&str> {
    marker_id(line, "END")
}

/// `line[%r{//\s*TMPL:(\S+)\s+#{kind}\s*$}, 1]` — a small hand-rolled
/// match standing in for the Ruby regex (no regex dependency here either).
fn marker_id<'a>(line: &'a str, kind: &str) -> Option<&'a str> {
    let idx = line.find("//")?;
    let mut rest = line[idx + 2..].trim_start();
    rest = rest.strip_prefix("TMPL:")?;
    let sp = rest.find(char::is_whitespace)?;
    let (id, tail) = rest.split_at(sp);
    if tail.trim() == kind {
        Some(id)
    } else {
        None
    }
}

/// Same idea as Ruby's `<<~` squiggly heredoc — drop whatever leading
/// whitespace every non-blank line shares.
fn dedent(lines: &[String]) -> String {
    let margin = lines
        .iter()
        .filter(|l| !l.trim().is_empty())
        .map(|l| l.len() - l.trim_start_matches([' ', '\t']).len())
        .min()
        .unwrap_or(0);
    let joined: String = lines
        .iter()
        .map(|l| if l.is_empty() { l.clone() } else { l.chars().skip(margin).collect::<String>() })
        .collect::<Vec<_>>()
        .join("");
    joined.trim_end().to_string()
}

fn parse_file(path: &std::path::Path, text: &str, result: &mut HashMap<String, String>) {
    // Each frame: (id, lines, begin_indent)
    let mut stack: Vec<(String, Vec<String>, String)> = Vec::new();
    for raw_line in text.split_inclusive('\n') {
        let line = raw_line;
        if let Some(id) = begin_marker(line) {
            let indent: String = line.chars().take_while(|c| *c == ' ' || *c == '\t').collect();
            stack.push((id.to_string(), Vec::new(), indent));
        } else if let Some(id) = end_marker(line) {
            let top = stack.last().map(|(top_id, _, _)| top_id.as_str());
            if stack.is_empty() || top != Some(id) {
                panic!(
                    "{}: TMPL:{id} END with no matching BEGIN (stack: {:?})",
                    path.display(),
                    stack.iter().map(|(i, _, _)| i.clone()).collect::<Vec<_>>()
                );
            }
            let (id, lines, begin_indent) = stack.pop().unwrap();
            let dedented = dedent(&lines);
            result.insert(id.clone(), dedented);
            if let Some((_, parent_lines, _)) = stack.last_mut() {
                parent_lines.push(format!("{begin_indent}<<TMPL_SLOT:{id}>>\n"));
            }
        } else if let Some((_, lines, _)) = stack.last_mut() {
            lines.push(line.to_string());
        }
    }
    if !stack.is_empty() {
        panic!("{}: unclosed TMPL region(s): {:?}", path.display(), stack.iter().map(|(i, _, _)| i.clone()).collect::<Vec<_>>());
    }
}
