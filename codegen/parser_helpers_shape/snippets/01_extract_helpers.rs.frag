/// Extract a `"..."` string literal from `line`, respecting backslash
/// escapes inside the quotes.
///
/// Two forms accepted, matching Ruby's parse semantics :
///
///   "simple"             → simple
///   "with \"quotes\""    → with "quotes"
///   "trailing \\"        → trailing \
///
/// Returns the UNESCAPED content (the way Ruby's `eval` of the string
/// literal would). Without the unescape step, Ruby's IR carries
/// `'with "quotes"'` while Rust would carry `'with \\"quotes\\"'` —
/// the escape-sequence parity drift that listed both
/// codegen/cli_dispatch_shape and codegen/parser_helpers_shape under
/// known_drift.txt. Both retire when this function unescapes correctly.
pub fn extract_string(line: &str) -> Option<String> {
    let start = line.find('"')? + 1;
    let mut out = String::new();
    let mut chars = line[start..].chars();
    while let Some(c) = chars.next() {
        if c == '\\' {
            // Recognised escape sequences mirror Ruby's basic set ;
            // anything else passes through with its leading backslash
            // dropped (so `\X` → `X`), matching Ruby's "ignore unknown
            // escape" behavior in double-quoted string literals.
            match chars.next() {
                Some('"')  => out.push('"'),
                Some('\\') => out.push('\\'),
                Some('n')  => out.push('\n'),
                Some('t')  => out.push('\t'),
                Some('r')  => out.push('\r'),
                Some('0')  => out.push('\0'),
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

/// Extract a possibly multi-line `"..."` string literal beginning on
/// `lines[start]`, returning the UNESCAPED content and the number of
/// physical lines consumed.
///
/// Mirrors Ruby's string-literal lexing : when the opening `"` is not
/// closed on the same physical line, the literal continues onto the next
/// raw (untrimmed) line with a `\n` re-inserted at each break, preserving
/// continuation-line indentation byte-for-byte. Single-line literals close
/// on the first iteration and return `(value, 1)`, identical to
/// `extract_string`. Used for top-level `vision` strings, which may span
/// several physical lines (paragraphs, arrows, backticked phrases) — Ruby
/// reads them natively because the DSL is `instance_eval`'d ; the Rust
/// line-walker must reassemble them to stay byte-equal.
///
/// Divergence (unreachable in the corpus, guarded by the parity gate) : a
/// backslash at the very end of a physical line is a Ruby line-continuation
/// that drops both the `\` and the newline ; here it yields a `\n`.
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
                    Some('"')  => out.push('"'),
                    Some('\\') => out.push('\\'),
                    Some('n')  => out.push('\n'),
                    Some('t')  => out.push('\t'),
                    Some('r')  => out.push('\r'),
                    Some('0')  => out.push('\0'),
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

/// Strip a trailing Ruby line-comment from `line`, returning the slice up
/// to (and trim-ending before) the first `#` that sits OUTSIDE a string
/// literal. Mirrors Ruby's lexer, which drops comments before the DSL
/// method is ever called — so `attribute :nickname, String  # "Trip"`
/// parses with type `String`, not `String  # "Trip"`. A `#` inside a
/// double-quoted string (e.g. `default: "#tag"`) is protected and left
/// intact. Lines with no out-of-string `#` are returned unchanged.
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

/// Two-string-form helper for `aggregate "Name", "Description" do` and
/// the matching `command`/`entity` shapes. Returns the UNESCAPED second
/// string — escape-aware throughout, mirroring `extract_string` above.
/// Embedded `\"` sequences in either string no longer prematurely
/// terminate parsing (the prior naïve `find('"')` scan truncated
/// descriptions containing escaped quotes — drift caught on
/// infrastructure.bluebook's adapter-family description).
pub fn extract_second_string(line: &str) -> Option<String> {
    // Skip past the first string with escape awareness.
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
    // Locate opening quote of the second string.
    let second_open_offset = line[idx..].find('"')?;
    let second_open = idx + second_open_offset + 1;
    // Read second string, unescaping the recognised set (mirrors
    // extract_string's behaviour : unknown `\X` collapses to `X`).
    let mut out = String::new();
    let mut chars = line[second_open..].chars();
    while let Some(c) = chars.next() {
        if c == '\\' {
            match chars.next() {
                Some('"')  => out.push('"'),
                Some('\\') => out.push('\\'),
                Some('n')  => out.push('\n'),
                Some('t')  => out.push('\t'),
                Some('r')  => out.push('\r'),
                Some('0')  => out.push('\0'),
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
    if sym.is_empty() { None } else { Some(sym) }
}

pub fn extract_word_after(line: &str, keyword: &str) -> Option<String> {
    let start = line.find(keyword)? + keyword.len();
    let rest = line[start..].trim();
    let end = rest
        .find(|c: char| !c.is_alphanumeric() && c != '_' && c != ':')
        .unwrap_or(rest.len());
    let word = rest[..end].trim().to_string();
    if word.is_empty() { None } else { Some(word) }
}

pub fn extract_block(line: &str) -> Option<String> {
    let start = line.find('{')? + 1;
    let end = line.rfind('}')?;
    Some(line[start..end].trim().to_string())
}

pub fn extract_after(line: &str, keyword: &str) -> Option<String> {
    let start = line.find(keyword)? + keyword.len();
    let rest = line[start..].trim();
    Some(rest.trim_end_matches(|c: char| c == ',' || c == ' ').to_string())
}

/// Extract a state token from `text`: either a quoted "string" or a bare
/// token like `true`, `false`, or `:symbol`. Used by lifecycle parsing
/// where Ruby happily stringifies `true`/`false`/symbols into the IR.
pub fn extract_state_token(text: &str) -> Option<String> {
    let t = text.trim_start();
    if t.starts_with('"') {
        return extract_string(t);
    }
    // Bare token — strip a leading `:` (symbol form) and read alphanumerics.
    let body = t.strip_prefix(':').unwrap_or(t);
    let end = body
        .find(|c: char| !c.is_alphanumeric() && c != '_')
        .unwrap_or(body.len());
    let tok = body[..end].trim().to_string();
    if tok.is_empty() { None } else { Some(tok) }
}

/// Check if line ends with ` do` (with optional block-arg list `|arg, ...|`).
/// Matches `... do`, `do`, and `... do |x|`, `... do |x, y|`.
///
/// Commented lines (those whose trimmed form starts with `#`) are
/// never block-openers — even if they contain `do` syntactically.
/// Without this guard, a commented-out `# query "cold" do` would
/// increment the parser's depth counter and swallow subsequent
/// top-level declarations as if they were nested inside the
/// phantom block. Closes the synapse.bluebook drift entry whose
/// commented `do` lines silently broke `query "alive"` resolution
/// on the Rust side ; Ruby's parser ignores comments natively.
pub fn ends_with_do_block(line: &str) -> bool {
    let trimmed = line.trim();
    if trimmed.starts_with('#') { return false; }
    if trimmed.ends_with(" do") || trimmed == "do" {
        return true;
    }
    // `... do |args|` — strip a trailing |...| if present
    if trimmed.ends_with('|') {
        if let Some(open) = trimmed[..trimmed.len() - 1].rfind('|') {
            let head = trimmed[..open].trim_end();
            return head.ends_with(" do") || head == "do";
        }
    }
    false
}

/// Extract a `kwarg: :symbol_name` pair from a DSL line. Returns the
/// symbol name (without the leading `:`) when found ; `None` when the
/// kwarg is absent or the value isn't a symbol.
///
/// Used by i250 to recognize `emits "X", identified_by: :stripe_event_id`
/// and pull `stripe_event_id` out cleanly. Generalises to other future
/// kwargs taking symbol values.
pub fn extract_kwarg_symbol(line: &str, kwarg: &str) -> Option<String> {
    let needle = format!("{kwarg}:");
    let start = line.find(&needle)? + needle.len();
    let rest = line[start..].trim_start();
    let rest = rest.strip_prefix(':')?;
    let end = rest
        .find(|c: char| !c.is_alphanumeric() && c != '_')
        .unwrap_or(rest.len());
    let sym = rest[..end].trim().to_string();
    if sym.is_empty() { None } else { Some(sym) }
}

