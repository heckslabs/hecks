/// Consume a `rule "..." do ... end` block on an aggregate / value_object /
/// entity. Tracks Ruby block-opener nesting through the body so multi-
/// statement constructs inside a `requires { ... }` (an `if/end`,
/// `case/end`, etc.) don't trip the surrounding parser's naive `end`
/// counter. Returns the number of source lines consumed (including the
/// closing `end`).
///
/// i259 — before this consumer existed, a multi-statement requires
/// body's inner `end` decremented the surrounding aggregate's depth,
/// silently truncating every command declared after the rule. That
/// dropped commands silently from the IR ; downstream dispatch fired
/// `unknown command : Aggregate.Command` far from the cause.
///
/// The consumer also validates the requires body shape : single boolean
/// expression only. Multi-statement bodies (an `if/else/end`, a `case`,
/// a `;`-separated sequence, etc.) panic with a structured RuleBodyError
/// message so the bluebook author sees file + line + body excerpt
/// instead of silent truncation.
///
/// Form recognised :
///   rule "name" do
///     requires { expr }                             — single line
///     requires { expr1 && expr2 ||                  — multi-line, single-expression
///                expr3 }
///     requires { if cond then a else b end }        — REJECTED (panic with hint)
///   end
///
/// Aggregate rules are not yet first-class IR — i246 lifts them. Until
/// then, this consumer's only job is to (a) consume the block cleanly
/// and (b) error loudly on multi-statement bodies. No IR is emitted ;
/// the rule is silently dropped (consistent with the Ruby DSL's
/// no-op `rule` method), but never silently drops surrounding siblings.
pub fn consume_rule_block(lines: &[&str]) -> usize {
    let first = lines[0].trim();
    let rule_name = extract_string(first).unwrap_or_default();

    // Single-line `rule "..." do ... end` form — rare but legal Ruby.
    // Body is whatever sits between ` do ` and the trailing ` end`.
    // We don't dig into it ; if a single-line rule contains a multi-
    // statement requires that's syntactically impossible anyway.
    if !ends_with_do_block(first) {
        return 1;
    }

    let mut depth: i32 = 1;
    let mut i = 1;
    while i < lines.len() && depth > 0 {
        let line = lines[i].trim();

        // Recognise `requires { ... }` first — its body is what we
        // validate. Single-line and multi-line brace forms both flow
        // through the same body collector.
        if line.starts_with("requires") {
            let after = &line["requires".len()..].trim_start();
            if after.starts_with('{') {
                let (body, body_end_idx) = read_requires_brace_body(lines, i);
                check_requires_body(&rule_name, &body, i + 1, body_end_idx + 1);
                i = body_end_idx + 1;
                continue;
            }
        }

        // Ruby-opener tracking. Every leading-keyword opener increments
        // depth ; every standalone `end` decrements. This is the surface
        // i259 added — without it, a bare `end` line inside a multi-
        // line `requires` body would close the rule prematurely.
        depth += count_rule_openers(line);
        if line == "end" {
            depth -= 1;
            if depth == 0 {
                return i + 1;
            }
        }
        i += 1;
    }

    // EOF without close — return what we walked. The surrounding
    // parser will surface its own structural error downstream.
    i
}

/// Read a `requires { ... }` body starting on `lines[start]`. Returns
/// the body text (without the outer braces) and the index of the last
/// line consumed (inclusive). Single-line and multi-line forms are
/// both supported ; brace balance respects nested `{`/`}` inside the
/// body so a hash literal inside requires doesn't terminate early.
fn read_requires_brace_body(lines: &[&str], start: usize) -> (String, usize) {
    let first = lines[start];
    let open_idx = match first.find('{') {
        Some(i) => i,
        None => return (String::new(), start),
    };
    let after_open = &first[open_idx + 1..];

    // Single-line case : the matching `}` lives on the same line.
    let mut depth: i32 = 1;
    for (idx, c) in after_open.char_indices() {
        match c {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if depth == 0 {
                    return (after_open[..idx].to_string(), start);
                }
            }
            _ => {}
        }
    }

    // Multi-line case : accumulate until depth returns to 0.
    let mut body = String::new();
    body.push_str(after_open);
    body.push('\n');

    let mut i = start + 1;
    while i < lines.len() && depth > 0 {
        let line = lines[i];
        for (idx, c) in line.char_indices() {
            match c {
                '{' => depth += 1,
                '}' => {
                    depth -= 1;
                    if depth == 0 {
                        body.push_str(&line[..idx]);
                        return (body.trim_end().to_string(), i);
                    }
                }
                _ => {}
            }
        }
        body.push_str(line);
        body.push('\n');
        i += 1;
    }

    (body.trim_end().to_string(), i.saturating_sub(1))
}

/// Validate the requires-block body is a single boolean expression.
/// Multi-statement bodies (`if/else/end`, `case/end`, semicolon-
/// separated statements, etc.) panic with the structured RuleBodyError
/// message named in i259 so authors see file + line + excerpt before
/// any IR truncation can hide the cause.
fn check_requires_body(rule_name: &str, body: &str, start_line: usize, end_line: usize) {
    let trimmed = body.trim();
    if trimmed.is_empty() {
        return;
    }

    let mut has_multi = false;
    let multi_keywords: &[&str] = &[
        "if ", "unless ", "case ", "begin", "while ", "until ",
        "else", "elsif", "when ", "for ",
    ];
    for raw in body.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') { continue; }
        for kw in multi_keywords {
            let kw_trim = kw.trim_end();
            if line == kw_trim || line.starts_with(kw) {
                has_multi = true;
                break;
            }
        }
        if line == "end" { has_multi = true; }
        if has_multi { break; }
    }

    // Top-level semicolon = explicit multi-statement.
    if !has_multi {
        let mut paren_depth: i32 = 0;
        for c in trimmed.chars() {
            match c {
                '(' | '[' | '{' => paren_depth += 1,
                ')' | ']' | '}' => paren_depth -= 1,
                ';' if paren_depth == 0 => { has_multi = true; break; }
                _ => {}
            }
        }
    }

    if !has_multi {
        return;
    }

    let hint = derive_requires_hint(trimmed)
        .unwrap_or_else(|| "Combine with `&&` / `||` or split into multiple `requires` blocks.".to_string());

    let mut excerpt = String::new();
    for line in trimmed.lines() {
        excerpt.push_str("                  ");
        excerpt.push_str(line);
        excerpt.push('\n');
    }

    panic!(
        "\nRuleBodyError\n  rule          : \"{}\"\n  block_lines   : {}..{}\n  body_excerpt  : |\n{}  message       : `requires {{ ... }}` body must be a single boolean expression. \\\n                  Multi-statement bodies aren't yet supported.\n  hint          : {}\n",
        rule_name, start_line, end_line, excerpt, hint
    );
}

/// Best-effort hint : if the body looks like a simple `if cond /
/// then_expr / else / else_expr / end`, propose the equivalent
/// boolean expression so the author can cut-and-paste. Returns None
/// when the shape isn't recognisable.
fn derive_requires_hint(body: &str) -> Option<String> {
    let mut iter = body.lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with('#'));
    let first = iter.next()?;
    let cond = first.strip_prefix("if ")?;
    let then_expr = iter.next()?;
    let else_kw = iter.next()?;
    if else_kw != "else" { return None; }
    let else_expr = iter.next()?;
    let end_kw = iter.next()?;
    if end_kw != "end" { return None; }
    if iter.next().is_some() { return None; }
    Some(format!(
        "Try : ({} && {}) || (!({}) && {})",
        cond.trim(), then_expr.trim(), cond.trim(), else_expr.trim()
    ))
}

/// Count Ruby block-opener delta on a line. Recognises the leading-
/// keyword openers (`if`, `unless`, `case`, `while`, `until`, `for`,
/// `begin`, `def`, `class`, `module`) and the trailing ` do` (with
/// optional `|args|`). Modifier-form `x if y` doesn't open a block
/// and is excluded by the leading-position check.
fn count_rule_openers(line: &str) -> i32 {
    let mut count: i32 = 0;
    let trimmed = line.trim();

    if ends_with_do_block(trimmed) {
        count += 1;
    }

    let openers: &[&str] = &[
        "if ", "unless ", "case ", "while ", "until ",
        "for ", "begin", "def ", "class ", "module ",
    ];
    for kw in openers {
        let kw_trim = kw.trim_end();
        if trimmed == kw_trim || trimmed.starts_with(kw) {
            count += 1;
            break;
        }
    }

    count
}

