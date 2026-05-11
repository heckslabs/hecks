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

pub fn extract_second_string(line: &str) -> Option<String> {
    let first_end = line.find('"')? + 1;
    let after_first = line[first_end..].find('"')? + first_end + 1;
    let start = line[after_first..].find('"')? + after_first + 1;
    let end = line[start..].find('"')? + start;
    Some(line[start..end].to_string())
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

