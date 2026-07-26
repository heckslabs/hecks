//! Block parsers — parse command, value_object, policy, lifecycle, attribute, mutation
//!
//! Each function takes a slice of lines starting at the block opener
//! and returns the parsed structure plus lines consumed.
//!
//! [antibody-exempt: i106 dsl-mutation-primitives — kernel-surface
//!  parser extension that recognizes `multiply:`, `clamp:`, and `decay:`
//!  on `then_set`. Same retirement contract as ir.rs : the .rs surface
//!  exists to enable pulse_organs.bluebook + consolidate retirement
//!  (i80 cli-routing-as-bluebook).]
//!
//! [antibody-exempt: i226 parse-where-comparator-hash-form — kernel-surface
//!  parser extension that recognizes `where(field: { lt|lte|gt|gte|ne: value })`
//!  hash-form comparators. The IR's WhereOp already carries every variant ;
//!  this is the parser side wiring that makes them reachable from .bluebook.
//!  Without it, queries like `Synapse.cold` (where last_fired_at < cutoff)
//!  cannot be expressed as first-class queries, and consolidate.sh /
//!  rem_branch.sh cannot retire (i221 / i222). Same retirement contract.]

use crate::ir::*;
use crate::parser_helpers::*;

/// Parse a top-level `section "Title" do … end` block from a capability
/// bluebook. Each `row "label", :field` line inside becomes one
/// SectionRow. Lines that aren't recognised are silently skipped so
/// authors can intersperse comments. Returns the parsed Section plus
/// the number of source lines consumed (including the closing `end`).
///
/// Form:
///   section "Identity" do
///     row "name",      :identity_name
///     row "born",      :born_at
///     row "age",       :age_str
///   end
///
/// `field` accepts both bare-symbol (`:foo`) and quoted string
/// (`"foo"`) tails so author intent reads naturally.
pub fn parse_section(lines: &[&str]) -> (Section, usize) {
    let first = lines[0].trim();
    let title = extract_string(first).unwrap_or_default();
    let mut rows: Vec<SectionRow> = Vec::new();
    let mut i = 1;
    let mut depth = 1usize;
    while i < lines.len() && depth > 0 {
        let line = lines[i].trim();
        if line == "end" {
            depth -= 1;
            if depth == 0 { break; }
            i += 1;
            continue;
        }
        if depth == 1 && (line.starts_with("row ") || line.starts_with("row\t")) {
            if let Some(row) = parse_section_row(line) {
                rows.push(row);
            }
        } else if ends_with_do_block(line) {
            depth += 1;
        }
        i += 1;
    }
    (Section { title, rows }, i + 1)
}

/// Parse one `row "label", :field` line. Field tail may be a bare
/// symbol (`:awareness_carrying`), a quoted string (`"awareness_carrying"`),
/// or a bare identifier. Returns None when the line shape is unparseable.
pub fn parse_section_row(line: &str) -> Option<SectionRow> {
    let label = extract_string(line)?;
    let after_label_close = {
        let first_open = line.find('"')?;
        let after = &line[first_open + 1..];
        let close = after.find('"')?;
        first_open + 1 + close + 1
    };
    let tail = line[after_label_close..].trim_start_matches(',').trim();
    let field = if tail.starts_with('"') {
        extract_string(tail)?
    } else if tail.starts_with(':') {
        extract_symbol(tail)?
    } else {
        // bare identifier — first contiguous run
        let end = tail.find(|c: char| !c.is_alphanumeric() && c != '_')
            .unwrap_or(tail.len());
        let f = tail[..end].trim();
        if f.is_empty() { return None; }
        f.to_string()
    };
    Some(SectionRow { label, field })
}

pub fn parse_command(lines: &[&str]) -> (Command, usize) {
    let first = lines[0].trim();
    let name = extract_string(first).unwrap_or_else(|| {
        // Shorthand: bare PascalCase like `CreatePizza do`
        first.split_whitespace().next().unwrap_or("").to_string()
    });

    let mut cmd = Command {
        name, description: None, role: None, attributes: vec![],
        references: vec![], emits: None, emits_identified_by: None,
        givens: vec![], mutations: vec![], redirects_native: vec![],
    };

    if first.contains("{") && first.contains("}") {
        parse_inline_command(first, &mut cmd);
        return (cmd, 1);
    }

    // Bare `command "Reset"` form — no `do` block, no body. Consume
    // just the single declaration line. Without this guard the loop
    // below walks past the closing `end` of the enclosing aggregate
    // and eats subsequent siblings, since the parser thinks it's
    // looking for a matching `end` that doesn't exist.
    if !ends_with_do_block(first) {
        return (cmd, 1);
    }

    let mut i = 1;
    let mut depth = 1;

    while i < lines.len() && depth > 0 {
        let line = lines[i].trim();

        if line == "end" {
            depth -= 1;
            if depth == 0 { break; }
            i += 1;
            continue;
        }

        if ends_with_do_block(line)
            && (depth > 1 || (!line.starts_with("attribute")
                && !line.starts_with("role")
                && !line.starts_with("given")
                && !line.starts_with("then_")))
            {
                depth += 1;
                i += 1;
                continue;
            }

        if depth == 1 {
            if line.starts_with("attribute") {
                if let Some(attr) = parse_attribute(line) { cmd.attributes.push(attr); }
            } else if is_shorthand_line(line) {
                match parse_shorthand(line) {
                    ShorthandResult::Attribute(a) => cmd.attributes.push(a),
                    ShorthandResult::Reference(r) => cmd.references.push(r),
                    ShorthandResult::None => {}
                }
            } else if line.starts_with("role") {
                cmd.role = parse_role_arg(line);
            } else if line.starts_with("goal") || line.starts_with("description") {
                cmd.description = extract_string(line);
            } else if line.starts_with("emits") {
                cmd.emits = extract_string(line);
                // i250 — events have identity. `emits "X", identified_by: :foo`
                // carries the event-identity attribute name. Same word
                // aggregates use for primary keys ; reused on the emit
                // side to dedupe two reports of the same event.
                cmd.emits_identified_by = extract_kwarg_symbol(line, "identified_by");
            } else if line.starts_with("redirects_native") {
                // This command is the governed door for one or more native
                // harness tools — `redirects_native "Edit", "MultiEdit"`. The
                // macrophage's governed-channel rule PROJECTS the native-tool
                // -> door map from every command carrying this ; door_args
                // derives from the command's attributes. A LIST : the quoted
                // tool names are the odd-indexed split-on-quote pieces.
                cmd.redirects_native = line.split('"').skip(1).step_by(2)
                    .map(|s| s.to_string()).collect();
            } else if line.starts_with("reference_to") {
                if let Some(target) = extract_word_after(line, "reference_to") {
                    // i526 : honour `, as: :name` and `, role: :name`
                    // qualifiers at the COMMAND level, the same way the
                    // aggregate-level `absorb_reference_to` does. Without
                    // this, transfer-style commands declaring two refs to
                    // the same aggregate (source + destination) collapse
                    // both names to the bare aggregate snake_case — making
                    // the IR ambiguous.
                    let name = if let Some(pos) = line.find(", as:") {
                        let after = &line[pos + ", as:".len()..];
                        extract_symbol(after).unwrap_or_else(|| to_snake_case(&target))
                    } else if let Some(pos) = line.find(", role:") {
                        let after = &line[pos + ", role:".len()..];
                        extract_symbol(after).unwrap_or_else(|| to_snake_case(&target))
                    } else {
                        to_snake_case(&target)
                    };
                    // Reference::single defaults to LegacyReferenceTo + single
                    // cardinality ; cardinality + kind ride into the IR via
                    // the impl helpers added by ImplReference fixture.
                    cmd.references.push(Reference::single(name, target, None));
                }
            } else if line.starts_with("given") {
                // Two forms:
                //   given "msg"         → expression = "msg", message = "msg"
                //   given { expr }      → expression = "expr", message = None
                //   given "msg" { expr }→ expression = "expr", message = "msg"
                // Strip the block first so quoted strings INSIDE the block
                // don't get picked up as the message argument.
                let block = extract_block(line);
                let line_no_block = match line.find('{') {
                    Some(open) => &line[..open],
                    None => line,
                };
                let msg = extract_string(line_no_block);
                let expr = block.unwrap_or_else(|| msg.clone().unwrap_or_default());
                cmd.givens.push(Given { expression: expr, message: msg });
            } else if line.starts_with("then_set") {
                if let Some(m) = parse_mutation(line) { cmd.mutations.push(m); }
            } else if line.starts_with("then_toggle") {
                if let Some(field) = extract_symbol(line) {
                    cmd.mutations.push(Mutation { field, operation: MutationOp::Toggle, value: String::new(), invalid_op: None });
                }
            } else if line.starts_with("then_delete") {
                // Record-level deletion. No field, no value — the op
                // alone says "remove this aggregate after dispatch".
                cmd.mutations.push(Mutation {
                    field: String::new(),
                    operation: MutationOp::Delete,
                    value: String::new(),
                    invalid_op: None,
                });
            }
        }
        i += 1;
    }
    (cmd, i + 1)
}

/// Extract the role/actor name from a `role …` line. Two forms accepted :
///
///   role "Customer"
///     Legacy quoted form — name is the literal string.
///
///   role Role[, as: Agent[, kind: "system"]]
///     i483 typed form — name is the bare identifier immediately after
///     `role`. The `as:` / `kind:` kwargs are accepted-and-ignored on
///     both Rust and Ruby sides until the parser-support follow-up
///     lifts them into the IR. Critically : the bareword form must
///     NOT fall back to extract_string, which would pick up the
///     quoted "system" inside a trailing `kind:` clause and silently
///     misidentify the role name.
fn parse_role_arg(line: &str) -> Option<String> {
    let after = line.trim_start_matches("role").trim_start();
    if after.starts_with('"') {
        return extract_string(after);
    }
    // Bareword form — read up to the first comma, whitespace, or
    // line end, and return the leading identifier.
    let end = after
        .find(|c: char| c == ',' || c.is_whitespace())
        .unwrap_or(after.len());
    let token = after[..end].trim();
    if token.is_empty() { None } else { Some(token.to_string()) }
}

/// Parse a `factory "X"[, produces: Y] do … end` block — a BIRTH
/// (2026-06-12 first-class-factories design). The body grammar is
/// identical to a command's (role, attributes, givens, emits,
/// then_set …), so the body is read by parse_command and lifted into
/// the Factory node. `produces:` names the aggregate this factory
/// mints ; None = the enclosing aggregate. The transitional `create`
/// keyword (#729) parses through here too until the phase-4 sweep.
pub fn parse_factory(lines: &[&str]) -> (Factory, usize) {
    let first = lines[0].trim();
    let produces = extract_produces(first);
    let (cmd, consumed) = parse_command(lines);
    let factory = Factory {
        name: cmd.name,
        description: cmd.description,
        role: cmd.role,
        produces,
        attributes: cmd.attributes,
        references: cmd.references,
        emits: cmd.emits,
        emits_identified_by: cmd.emits_identified_by,
        givens: cmd.givens,
        mutations: cmd.mutations,
    };
    (factory, consumed)
}

/// Extract the bare-constant target of a `produces:` kwarg —
/// `factory "DraftStory", produces: Story do` → Some("Story").
/// Bare PascalCase ident ; trailing `do` / `,` / `{` delimiters end it.
fn extract_produces(first: &str) -> Option<String> {
    let pos = first.find("produces:")?;
    let after = first[pos + "produces:".len()..].trim_start();
    let end = after
        .find(|c: char| !(c.is_alphanumeric() || c == '_' || c == ':'))
        .unwrap_or(after.len());
    let token = after[..end].trim().trim_end_matches(':');
    if token.is_empty() { None } else { Some(token.to_string()) }
}

fn parse_inline_command(line: &str, cmd: &mut Command) {
    if let Some(block) = extract_block(line) {
        for part in block.split(';') {
            let part = part.trim();
            if part.starts_with("role") {
                cmd.role = parse_role_arg(part);
            } else if part.starts_with("emits") {
                cmd.emits = extract_string(part);
                cmd.emits_identified_by = extract_kwarg_symbol(part, "identified_by");
            } else if part.starts_with("attribute") {
                if let Some(attr) = parse_attribute(part) { cmd.attributes.push(attr); }
            } else if part.starts_with("reference_to") {
                if let Some(target) = extract_word_after(part, "reference_to") {
                    let snake = to_snake_case(&target);
                    // Reference gained `cardinality` + `kind` for the
                    // Sprint 7 relationship DSL ; the inline command
                    // path constructs via Reference::single (LegacyReferenceTo
                    // + single cardinality defaults) so the new fields
                    // are populated without per-callsite repetition.
                    cmd.references.push(Reference::single(snake, target, None));
                }
            } else if is_shorthand_line(part) {
                match parse_shorthand(part) {
                    ShorthandResult::Attribute(a) => cmd.attributes.push(a),
                    ShorthandResult::Reference(r) => cmd.references.push(r),
                    ShorthandResult::None => {}
                }
            }
        }
    }
}

/// Parse a `query "Name" do ... end` block — i101 first-class query IR.
///
/// Body lines recognized:
///   - `description "..."`     — human-readable goal
///   - `attribute :name, Type` — input parameter (kwarg at dispatch)
///   - `where field: value`    — filter clause (eq op default)
///   - `where(field: value)`   — same, parenthesized form
///   - `order_by :field`       — sort ascending
///   - `order_by :field, :desc`— sort descending
///   - `limit 10`              — record cap (literal)
///   - `limit :max`            — record cap (kwarg-ref)
///
/// The block opener may carry a `|param|` argument list for the legacy
/// `query "ByX" do |x| where(field: x) end` form ; the parser maps the
/// param to an implicit String attribute so `where` can resolve `:x`.
pub fn parse_query(lines: &[&str]) -> (Query, usize) {
    let first = lines[0].trim();
    // `query "Foo"` (quoted) vs `query Foo` (bare PascalCase) — the
    // bare form falls through to the second whitespace-split token,
    // matching push_query's legacy behavior.
    let name = extract_string(first).unwrap_or_else(|| {
        first.split_whitespace().nth(1).unwrap_or("").trim_matches('"').to_string()
    });

    let mut q = Query {
        name,
        description: None,
        attributes: vec![],
        wheres: vec![],
        order_by: None,
        limit: None,
        reduction: None,
        group_by: None,
        scope_to: None,
    };

    // Capture `do |arg, ...|` block params as implicit String attributes.
    // The legacy `query "ByX" do |x| where(field: x) end` form binds `x`
    // as a positional kwarg ; the runtime resolves `:x` via attrs at
    // dispatch time, same as named-attribute kwargs.
    if let Some(open) = first.rfind('|') {
        if let Some(prev) = first[..open].rfind('|') {
            let inside = &first[prev + 1..open];
            for part in inside.split(',') {
                let nm = part.trim().trim_start_matches(':').to_string();
                if !nm.is_empty() {
                    q.attributes.push(Attribute {
                        name: nm,
                        attr_type: "String".to_string(),
                        default: None,
                        list: false,
                        required: false,
                        enum_values: vec![],
                pattern: None, hint: None, logged: true,
                    });
                }
            }
        }
    }

    let mut i = 1;
    let mut depth = 1;
    while i < lines.len() && depth > 0 {
        let line = lines[i].trim();
        if line == "end" {
            depth -= 1;
            if depth == 0 { break; }
            i += 1;
            continue;
        }
        if depth == 1 {
            if line.starts_with("description") {
                q.description = extract_string(line);
            } else if line.starts_with("attribute") {
                if let Some(attr) = parse_attribute(line) { q.attributes.push(attr); }
            } else if line.starts_with("where") {
                let param_names: Vec<String> = q.attributes.iter()
                    .map(|a| a.name.clone()).collect();
                for w in parse_where_line(line, &param_names) {
                    q.wheres.push(w);
                }
            } else if line.starts_with("order_by") {
                if let Some(ob) = parse_order_by_line(line) { q.order_by = Some(ob); }
            } else if line.starts_with("limit") {
                if let Some(ls) = parse_limit_line(line) { q.limit = Some(ls); }
            } else if line == "count" || line.starts_with("count ") || line.starts_with("count\t") {
                // deciderate Layer 0a — scalar reductions. `count` needs no
                // field ; sum/max/min/median fold the named numeric field.
                q.reduction = Some(Reduction::Count);
            } else if line.starts_with("sum") {
                if let Some(f) = extract_symbol(line) { q.reduction = Some(Reduction::Sum(f)); }
            } else if line.starts_with("median") {
                if let Some(f) = extract_symbol(line) { q.reduction = Some(Reduction::Median(f)); }
            } else if line.starts_with("max") {
                if let Some(f) = extract_symbol(line) { q.reduction = Some(Reduction::Max(f)); }
            } else if line.starts_with("min") {
                if let Some(f) = extract_symbol(line) { q.reduction = Some(Reduction::Min(f)); }
            } else if line.starts_with("group_by") {
                // partition the matched set by this field's value
                if let Some(f) = extract_symbol(line) { q.group_by = Some(f); }
            } else if line.starts_with("scope_to") {
                // read-authZ row-scope : inject where(field == :actor) at run time
                if let Some(f) = extract_symbol(line) { q.scope_to = Some(f); }
            } else if ends_with_do_block(line) {
                depth += 1;
            }
        } else if ends_with_do_block(line) {
            depth += 1;
        }
        i += 1;
    }
    (q, i + 1)
}

/// Parse one `where ...` line into one or more WhereClauses.
///
/// Forms recognized :
///   where field: value                  (hash form, eq)
///   where(field: value)                 (parenthesized hash form, eq)
///   where field1: v1, field2: v2        (multi-pair, all eq)
///   where(field: { lt: value })         (comparator hash form — i226)
///   where(field: { lte: value })
///   where(field: { gt: value })
///   where(field: { gte: value })
///   where(field: { ne: value })
///
/// Values are captured as canonical source tokens : `"available"` keeps
/// its quotes stripped → "available" ; `:author` keeps its colon prefix
/// → ":author" so the runtime can detect the kwarg-ref form. Bare
/// identifiers that match a known query parameter name (passed in
/// `param_names`) are also rendered with a leading colon — the legacy
/// `query "ByX" do |x| where(field: x) end` form binds `x` as a
/// kwarg-ref the same way `:x` would.
pub fn parse_where_line(line: &str, param_names: &[String]) -> Vec<WhereClause> {
    // Strip leading `where(` or `where ` ; if parenthesized, drop the
    // matching close paren too.
    let mut body = line.trim_start_matches("where").trim_start();
    let parenthesized = body.starts_with('(');
    if parenthesized {
        body = body.trim_start_matches('(');
        if let Some(close) = body.rfind(')') {
            body = &body[..close];
        }
    }
    let mut out = Vec::new();
    for part in split_top_level_commas(body) {
        let part = part.trim();
        if part.is_empty() { continue; }
        if let Some(colon) = part.find(':') {
            let field = part[..colon].trim().to_string();
            let raw = part[colon + 1..].trim();
            if field.is_empty() { continue; }
            // Comparator hash form: `field: { op: value }`. Recognize
            // op key, recurse into value extraction.
            if raw.starts_with('{') {
                if let Some((op, inner)) = parse_comparator_hash(raw) {
                    let value = extract_where_value(inner, param_names);
                    out.push(WhereClause { field, op, value });
                    continue;
                }
            }
            let value = extract_where_value(raw, param_names);
            out.push(WhereClause {
                field,
                op: WhereOp::Eq,
                value,
            });
        }
    }
    out
}

/// Extract the canonical value token from a where-clause RHS, applying
/// the kwarg-ref convention (bare identifiers that match a query param
/// name get a leading colon).
fn extract_where_value(raw: &str, param_names: &[String]) -> String {
    let raw = raw.trim();
    if raw.starts_with('"') {
        extract_string(raw).unwrap_or_default()
    } else if raw.starts_with('\'') {
        // Single-quoted string literal — strip enclosing quotes.
        // Used in multi-key where conditions that mix a runtime-param key
        // with a literal value, e.g. `where person: :person, status: 'drafting'`.
        // Without this branch the quotes are carried into the IR and the
        // runtime comparison `"drafting" == "'drafting'"` always fails.
        let inner = raw.trim_start_matches('\'');
        let close = inner.rfind('\'').unwrap_or(inner.len());
        inner[..close].to_string()
    } else if raw.starts_with('[') {
        // List literal for the `in:` operator. Normalize to a clean CSV of
        // items (quotes + whitespace stripped) ; where_matches splits on
        // ',' for membership. Inner commas are elements, already protected
        // by split_top_level_commas' bracket-depth tracking.
        let inner = raw.trim_start_matches('[');
        let close = inner.rfind(']').unwrap_or(inner.len());
        split_top_level_commas(&inner[..close])
            .iter()
            .map(|it| it.trim().trim_matches('"').trim_matches('\'').trim().to_string())
            .filter(|s| !s.is_empty())
            .collect::<Vec<_>>()
            .join(",")
    } else if raw.starts_with(':') {
        raw.split(|c: char| c == ',' || c.is_whitespace())
            .next().unwrap_or("").to_string()
    } else {
        let token = raw.split(|c: char| c == ',' || c.is_whitespace())
            .next().unwrap_or("").to_string();
        if param_names.iter().any(|p| p == &token) {
            format!(":{}", token)
        } else {
            token
        }
    }
}

/// Parse a comparator hash like `{ lt: "2026-05-01T00:00:00Z" }` into
/// the matching WhereOp variant plus the inner value source. Returns
/// None if the brace form is malformed or the op key is unrecognized.
fn parse_comparator_hash(raw: &str) -> Option<(WhereOp, &str)> {
    let raw = raw.trim_start_matches('{');
    let close = raw.rfind('}')?;
    let inner = raw[..close].trim();
    let colon = inner.find(':')?;
    let op_key = inner[..colon].trim().trim_start_matches(':');
    let value_part = inner[colon + 1..].trim();
    let op = match op_key {
        "lt"  => WhereOp::Lt,
        "lte" => WhereOp::Lte,
        "gt"  => WhereOp::Gt,
        "gte" => WhereOp::Gte,
        "ne"  => WhereOp::Ne,
        "eq"  => WhereOp::Eq,
        "in"  => WhereOp::In,
        "none_in_state" => WhereOp::NoneInState,
        "contains" => WhereOp::Contains,
        _     => return None,
    };
    Some((op, value_part))
}


/// Parse `order_by :field` or `order_by :field, :desc` into an OrderBy.
pub fn parse_order_by_line(line: &str) -> Option<OrderBy> {
    let body = line.trim_start_matches("order_by").trim();
    let body = body.trim_start_matches('(').trim_end_matches(')');
    let parts: Vec<&str> = body.split(',').map(|s| s.trim()).collect();
    let field_part = parts.first()?;
    let field = field_part.trim_start_matches(':').to_string();
    if field.is_empty() { return None; }
    let direction = match parts.get(1).map(|s| s.trim_start_matches(':')) {
        Some("desc") | Some("Desc") | Some("DESC") => Direction::Desc,
        _ => Direction::Asc,
    };
    Some(OrderBy { field, direction })
}

/// Parse `limit 10` or `limit :max_results` into a LimitSpec.
pub fn parse_limit_line(line: &str) -> Option<LimitSpec> {
    let body = line.trim_start_matches("limit").trim();
    let body = body.trim_start_matches('(').trim_end_matches(')');
    let token = body.split(|c: char| c == ',' || c.is_whitespace())
        .next()?
        .trim();
    if token.is_empty() { return None; }
    Some(LimitSpec { value: token.to_string() })
}

/// Split a member line's body on top-level commas, quote-aware —
/// `code: "USD", symbol: "C$", minor_units: 2` → three pairs even when a
/// quoted value contains a comma.
fn split_member_pairs(s: &str) -> Vec<&str> {
    let mut pairs = Vec::new();
    let mut in_quotes = false;
    let mut last = 0;
    for (i, c) in s.char_indices() {
        match c {
            '"' => in_quotes = !in_quotes,
            ',' if !in_quotes => {
                pairs.push(&s[last..i]);
                last = i + 1;
            }
            _ => {}
        }
    }
    if last < s.len() {
        pairs.push(&s[last..]);
    }
    pairs
}

/// Parse a `derive :name, ReturnType` header (the text between `derive` and
/// ` do`) into (name, return_type). The leading `:` on the name is stripped.
/// Returns None when either the name or the return type is missing.
fn parse_derive_signature(header: &str) -> Option<(String, String)> {
    let sig = header.trim();
    let comma = sig.find(',')?;
    let name = sig[..comma].trim().trim_start_matches(':').to_string();
    let rtype = sig[comma + 1..].trim().to_string();
    if name.is_empty() || rtype.is_empty() { return None; }
    Some((name, rtype))
}

/// Split a `|a, b| rest` block body into its parameter NAMES and the
/// remaining expression text. A body with no `|params|` prefix returns
/// (empty, whole body).
fn split_block_params(body: &str) -> (Vec<String>, &str) {
    let body = body.trim();
    if let Some(rest) = body.strip_prefix('|') {
        if let Some(close) = rest.find('|') {
            let params = rest[..close]
                .split(',')
                .map(|p| p.trim().to_string())
                .filter(|p| !p.is_empty())
                .collect();
            return (params, rest[close + 1..].trim());
        }
    }
    (Vec::new(), body)
}

pub fn parse_value_object(lines: &[&str]) -> (ValueObject, usize) {
    let first = lines[0].trim();
    let name = extract_string(first).unwrap_or_default();
    let mut vo = ValueObject { name, description: None, attributes: vec![], invariants: vec![], derivations: vec![], members: vec![] };

    let mut i = 1;
    let mut depth = 1;
    while i < lines.len() && depth > 0 {
        let line = lines[i].trim();
        if line == "end" {
            depth -= 1;
            if depth == 0 { break; }
        } else if depth == 1 && (line.starts_with("rule ") || line.starts_with("rule\t")) {
            // i259 — `rule "..." do ... end` on a value_object delegates
            // to consume_rule_block so a multi-statement `requires` body
            // can't decrement the surrounding depth.
            let consumed = consume_rule_block(&lines[i..]);
            i += consumed;
            continue;
        } else if depth == 1 && (line == "one_of do" || line.starts_with("one_of do")) {
            // Closed whole-value set (GRAMMAR-one-of, 2026-07-19) :
            //   one_of do
            //     member code: "USD", symbol: "$", minor_units: 2
            //   end
            // Each member line's ordered key:value pairs become one member ;
            // declaration order is the parity contract (Ruby kwargs preserve
            // insertion order). Values : quoted strings verbatim, bare
            // tokens (numbers) stringified.
            let mut j = i + 1;
            let mut d = 1;
            while j < lines.len() && d > 0 {
                let l = lines[j].trim();
                if l == "end" {
                    d -= 1;
                    if d == 0 { break; }
                } else if ends_with_do_block(l) {
                    d += 1;
                } else if l.starts_with("member ") || l.starts_with("member(") {
                    let body = l.trim_start_matches("member").trim_start_matches('(').trim_end_matches(')');
                    let mut fields: Vec<(String, String)> = Vec::new();
                    for pair in split_member_pairs(body) {
                        if let Some(colon) = pair.find(':') {
                            let key = pair[..colon].trim().trim_matches(':').to_string();
                            let raw_val = pair[colon + 1..].trim();
                            let val = extract_string(raw_val)
                                .unwrap_or_else(|| raw_val.trim_matches(',').trim().to_string());
                            if !key.is_empty() && !val.is_empty() {
                                fields.push((key, val));
                            }
                        }
                    }
                    if !fields.is_empty() {
                        vo.members.push(fields);
                    }
                }
                j += 1;
            }
            i = j + 1;
            continue;
        } else if depth == 1
            && line.starts_with("invariant")
            && line.contains('{')
            && line.ends_with('}')
        {
            // VO-level invariant, BRACE form :
            //   invariant("an address routes somewhere") { address.include?("@") }
            //
            // Ruby takes a block either way — `do … end` and `{ … }` are the
            // same construct — so a parser that reads only one accepts a
            // NARROWER language than the DSL does, and a bluebook can then be
            // valid Ruby and invisible here. That is what happened : the
            // library's own grammar/expression.bluebook is written in this form,
            // and Rust silently read 2 of its 6 invariants while Ruby read all
            // six. Nothing failed, because an invariant nobody parses looks
            // exactly like an invariant that holds.
            let inv_name = extract_string(line).unwrap_or_default();
            if let (Some(open), Some(stripped)) = (line.find('{'), line.strip_suffix('}')) {
                let expr = stripped[open + 1..].trim();
                if !inv_name.is_empty() && !expr.is_empty() {
                    vo.invariants.push(Invariant { name: inv_name, expression: expr.to_string() });
                }
            }
        } else if depth == 1 && line.starts_with("invariant") && line.contains(" do ") && line.ends_with("end") {
            // VO-level invariant, INLINE one-liner form (inbox.bluebook's
            // CommitSha) : invariant "non-empty" do value.length > 0 end
            // The whole block sits on one line, so ends_with_do_block is
            // false and the multi-line arm below never fires — the parity
            // contract caught this gap the same day the field joined the
            // canonical IR.
            let inv_name = extract_string(line).unwrap_or_default();
            if let (Some(do_pos), Some(stripped)) = (line.find(" do "), line.strip_suffix("end")) {
                let expr = stripped[do_pos + " do ".len()..].trim();
                if !inv_name.is_empty() && !expr.is_empty() {
                    vo.invariants.push(Invariant { name: inv_name, expression: expr.to_string() });
                }
            }
        } else if depth == 1 && line.starts_with("invariant") && ends_with_do_block(line) {
            // VO-level invariant — the Pizzas-canon direct-predicate form :
            //   invariant "must be non-negative" do
            //     cents >= 0
            //   end
            // (Aggregate-level invariants use the separate `holds_when` form ;
            // this one's body IS the predicate.) Body lines join with ` && `
            // for the rare multi-line predicate. Before 2026-07-18 this arm
            // was missing and the block fell through to the generic do-block
            // depth tracking — parsed to nowhere, silently dropped.
            let inv_name = extract_string(line).unwrap_or_default();
            let mut body: Vec<&str> = Vec::new();
            let mut j = i + 1;
            let mut d = 1;
            while j < lines.len() && d > 0 {
                let l = lines[j].trim();
                if l == "end" {
                    d -= 1;
                    if d == 0 { break; }
                } else if ends_with_do_block(l) {
                    d += 1;
                }
                if d >= 1 && !l.is_empty() {
                    body.push(l);
                }
                j += 1;
            }
            if !inv_name.is_empty() && !body.is_empty() {
                vo.invariants.push(Invariant { name: inv_name, expression: body.join(" && ") });
            }
            i = j + 1;
            continue;
        } else if depth == 1 && line.starts_with("derive") && line.contains(" do ") && line.ends_with("end") {
            // Pure derivation, INLINE one-liner (rich-VO behaviour half) :
            //   derive :zero?,   Boolean do cents == 0 end
            //   derive :covers?, Boolean do |other| cents >= other.cents end
            if let (Some(do_pos), Some(stripped)) = (line.find(" do "), line.strip_suffix("end")) {
                let header = &line["derive".len()..do_pos];
                if let Some((name, rtype)) = parse_derive_signature(header) {
                    let raw_body = stripped[do_pos + " do ".len()..].trim();
                    let (params, expr) = split_block_params(raw_body);
                    if !expr.is_empty() {
                        vo.derivations.push(Derivation { name, return_type: rtype, params, expression: expr.to_string() });
                    }
                }
            }
        } else if depth == 1 && line.starts_with("derive") && ends_with_do_block(line) {
            // Pure derivation, multi-line form :
            //   derive :covers?, Boolean do |other|
            //     cents >= other.cents
            //   end
            let do_pos = line.find(" do").unwrap_or(line.len());
            let header = &line["derive".len()..do_pos];
            let after_do = line[do_pos + " do".len()..].trim();
            let (params, _) = split_block_params(after_do);
            let mut body: Vec<&str> = Vec::new();
            let mut j = i + 1;
            let mut d = 1;
            while j < lines.len() && d > 0 {
                let l = lines[j].trim();
                if l == "end" {
                    d -= 1;
                    if d == 0 { break; }
                } else if ends_with_do_block(l) {
                    d += 1;
                }
                if d >= 1 && !l.is_empty() {
                    body.push(l);
                }
                j += 1;
            }
            if let Some((name, rtype)) = parse_derive_signature(header) {
                if !body.is_empty() {
                    vo.derivations.push(Derivation { name, return_type: rtype, params, expression: body.join(" && ") });
                }
            }
            i = j + 1;
            continue;
        } else if ends_with_do_block(line) {
            depth += 1;
        }
        if depth == 1 {
            if line.starts_with("description") { vo.description = extract_string(line); }
            if line.starts_with("attribute") {
                if let Some(attr) = parse_attribute(line) { vo.attributes.push(attr); }
            } else if is_shorthand_line(line) && !line.starts_with("reference_to(") {
                if let Some(attr) = parse_shorthand_attribute(line) { vo.attributes.push(attr); }
            }
        }
        i += 1;
    }
    (vo, i + 1)
}

/// Parse a non-root entity block — DDD entity owned by its parent
/// aggregate. Entities have identity within the parent boundary and
/// can mutate (unlike value_objects which are immutable and replaced
/// wholesale). Distinct from a top-level aggregate : reachable only
/// through the parent root, lifecycle bounded by the parent.
///
/// i111-J — entity blocks now accept `command`, `query`, and
/// `lifecycle` declarations the same way aggregates do. The runtime
/// dispatches them as `Aggregate.Entity.Command` (3-part) or
/// `Aggregate.Command` when the bare name is unique among the
/// parent's entities. This closes the DDD-depth gap : authors who
/// collapse an aggregate into an entity no longer have to flatten
/// behaviors `on:` clauses to the parent root.
pub fn parse_entity(lines: &[&str]) -> (Entity, usize) {
    let first = lines[0].trim();
    let name = extract_string(first).unwrap_or_default();
    let mut ent = Entity {
        name,
        description: None,
        attributes: vec![],
        commands: vec![],
        queries: vec![],
        lifecycle: None,
        identified_by: None,
    };

    let mut i = 1;
    let mut depth = 1;
    while i < lines.len() && depth > 0 {
        let line = lines[i].trim();

        if line == "end" {
            depth -= 1;
            if depth == 0 { break; }
            i += 1;
            continue;
        }

        if depth == 1 {
            if line.starts_with("command") || is_shorthand_command(line) {
                let (cmd, consumed) = parse_command(&lines[i..]);
                ent.commands.push(cmd);
                i += consumed;
                continue;
            } else if line.starts_with("query") {
                // i101 — block-form queries delegate to parse_query so
                // entity-scoped queries get the same structured IR as
                // aggregate-scoped ones.
                if ends_with_do_block(line) {
                    let (q, consumed) = parse_query(&lines[i..]);
                    ent.queries.push(q);
                    i += consumed;
                    continue;
                }
                let q_name = extract_string(line).unwrap_or_else(|| {
                    line.split_whitespace().nth(1).unwrap_or("").trim_matches('"').to_string()
                });
                let q_desc = extract_second_string(line);
                ent.queries.push(Query {
                    name: q_name,
                    description: q_desc,
                    attributes: vec![],
                    wheres: vec![],
                    order_by: None,
                    limit: None,
                    reduction: None,
                    group_by: None,
                    scope_to: None,
                });
            } else if line.starts_with("lifecycle") {
                let (lc, consumed) = parse_lifecycle(&lines[i..]);
                ent.lifecycle = Some(lc);
                i += consumed;
                continue;
            } else if line.starts_with("identified_by") {
                ent.identified_by = extract_symbol(line);
            } else if line.starts_with("description") {
                ent.description = extract_string(line);
            } else if line.starts_with("attribute") {
                if let Some(attr) = parse_attribute(line) { ent.attributes.push(attr); }
                if ends_with_do_block(line) {
                    // attribute-with-lifecycle sugar (same shape as on
                    // aggregate) — parse_lifecycle reads symbol + default
                    // off the same first line.
                    let (lc, consumed) = parse_lifecycle(&lines[i..]);
                    if !lc.transitions.is_empty() { ent.lifecycle = Some(lc); }
                    i += consumed;
                    continue;
                }
            } else if is_shorthand_line(line) && !line.starts_with("reference_to(") {
                if let Some(attr) = parse_shorthand_attribute(line) { ent.attributes.push(attr); }
            } else if line.starts_with("rule ") || line.starts_with("rule\t") {
                // i259 — `rule "..." do ... end` on an entity delegates
                // to consume_rule_block so a multi-statement `requires`
                // body can't decrement the surrounding depth.
                let consumed = consume_rule_block(&lines[i..]);
                i += consumed;
                continue;
            } else if ends_with_do_block(line) {
                depth += 1;
            }
        } else if ends_with_do_block(line) {
            depth += 1;
        }

        i += 1;
    }
    (ent, i + 1)
}

pub fn parse_policy(lines: &[&str]) -> (Policy, usize) {
    let first = lines[0].trim();
    let name = extract_string(first).unwrap_or_default();
    let mut on_event = String::new();
    let mut trigger = String::new();
    let mut target_domain = None;
    // Gap #1 of the adapters-as-bluebook arc — literal args the policy
    // passes to its triggered command. `with "key", "value"` parses to
    // (key, ValueSpec::Literal { value }). One key per line, ordered.
    // This is the minimal extension that lets a policy fire
    // `Primitive::Process.Spawn cmd="…" result_into="Cascade.RecordResult"`
    // — the data the retired :exec resolver used to inline. Only the
    // two-string literal form is parsed here ; the state-aware specs
    // (from_state/templating) are deferred to later families.
    let mut with: Vec<(String, crate::ir::ValueSpec)> = vec![];
    // deciderate Layer 0b — the grown policy : data guard, fan-out, extra reactions.
    let mut wheres: Vec<crate::ir::WhereClause> = vec![];
    let mut for_each: Option<crate::ir::ForEachSpec> = None;
    let mut extra_dispatches: Vec<crate::ir::DispatchSpec> = vec![];

    let mut i = 1;
    while i < lines.len() {
        let line = lines[i].trim();
        if line == "end" { break; }
        if line.starts_with("on") { on_event = extract_string(line).unwrap_or_default(); }
        if line.starts_with("trigger") { trigger = extract_string(line).unwrap_or_default(); }
        if line.starts_with("across") { target_domain = extract_string(line); }
        if line.starts_with("with") {
            if let (Some(key), Some(value)) =
                (extract_string(line), extract_second_string(line))
            {
                with.push((key, crate::ir::ValueSpec::Literal { value }));
            }
        }
        // Cross-field payload map — `map key: :event_field, key2: "literal"`.
        // Routes the triggering event's data (+ static literals) INTO the
        // TRIGGERED command's attributes, renaming as declared. This is what
        // makes a cascade route : `map account: :destination` sends the
        // triggered Deposit to the DESTINATION account, not the upstream
        // aggregate. Reuses `with` (both are (command_attr, ValueSpec) args) :
        // a `:symbol` value is a FromEvent rename, a "string"/number a Literal.
        // Before 2026-07-21 the parser dropped `map` entirely, so every
        // cross-aggregate cascade mis-routed (the transfer saga's root bug).
        if line.starts_with("map ") {
            let body = line.strip_prefix("map").unwrap_or("").trim();
            for pair in split_member_pairs(body) {
                if let Some(colon) = pair.find(':') {
                    let key = pair[..colon].trim().to_string();
                    let raw_val = pair[colon + 1..].trim();
                    if key.is_empty() || raw_val.is_empty() { continue; }
                    let spec = if let Some(sym) = raw_val.strip_prefix(':') {
                        crate::ir::ValueSpec::FromEvent { name: sym.trim().to_string(), default: None }
                    } else if raw_val.starts_with('"') || raw_val.starts_with('\'') {
                        crate::ir::ValueSpec::Literal { value: extract_string(raw_val).unwrap_or_default() }
                    } else {
                        crate::ir::ValueSpec::Literal { value: raw_val.trim_matches(',').trim().to_string() }
                    };
                    with.push((key, spec));
                }
            }
        }
        // 0b guard — `where field: value` reuses the query WhereClause grammar.
        if line.starts_with("where") {
            for w in parse_where_line(line, &[]) { wheres.push(w); }
        }
        // 0b fan-out — standalone `for_each: { from: "Agg.query" }` sweeps the
        // primary trigger (reuses the i221-A clause parser).
        if line.starts_with("for_each") {
            if let Some(fe) = parse_for_each_clause(line) { for_each = Some(fe); }
        }
        // 0b multi-reaction — each `dispatch "Cmd", with: {..}, for_each: {..}`
        // adds a reaction beyond the primary trigger.
        if is_dispatch_start(line) {
            if let Some(ds) = parse_dispatch_statement(line) { extra_dispatches.push(ds); }
        }
        i += 1;
    }
    (Policy { name, on_event, trigger_command: trigger, target_domain, with, wheres, for_each, extra_dispatches }, i + 1)
}

pub fn parse_lifecycle(lines: &[&str]) -> (Lifecycle, usize) {
    let first = lines[0].trim();
    let field = extract_symbol(first).unwrap_or_default();
    // `default:` accepts a quoted string OR a bare token (`true`, `false`,
    // `:symbol`) — match the Ruby DSL which stringifies any of these.
    let default = if first.contains("default:") {
        let after = extract_after(first, "default:").unwrap_or_default();
        extract_state_token(&after).unwrap_or_default()
    } else { String::new() };

    let mut transitions = vec![];
    let mut i = 1;
    while i < lines.len() {
        let line = lines[i].trim();
        if line == "end" { break; }
        if line.starts_with("transition") {
            if let Some(cmd) = extract_string(line) {
                // to_state: token after `=>` — quoted, bare, or `:symbol`.
                let to_state = line
                    .find("=>")
                    .and_then(|arrow| extract_state_token(&line[arrow + 2..]));
                // Collect ALL from states. `from: "a"` → [Some("a")];
                // `from: ["a", "b"]` → [Some("a"), Some("b")]; absent → [None].
                // Bare tokens (`true`/`false`/`:sym`) also accepted.
                let from_states: Vec<Option<String>> = if line.contains("from:") {
                    let after = extract_after(line, "from:").unwrap_or_default();
                    let trimmed = after.trim_start();
                    if trimmed.starts_with('[') {
                        // Array form — split on commas inside the brackets and
                        // extract a state token from each element.
                        let close = trimmed.find(']').unwrap_or(trimmed.len());
                        let inner = &trimmed[1..close];
                        let found: Vec<Option<String>> = inner
                            .split(',')
                            .filter_map(|part| extract_state_token(part).map(Some))
                            .collect();
                        if found.is_empty() { vec![None] } else { found }
                    } else {
                        vec![extract_state_token(&after)]
                    }
                } else { vec![None] };
                if let Some(to) = to_state {
                    for from_state in from_states {
                        transitions.push(Transition {
                            command: cmd.clone(), to_state: to.clone(), from_state
                        });
                    }
                }
            }
        }
        i += 1;
    }
    (Lifecycle { field, default, transitions }, i + 1)
}

pub fn parse_attribute(line: &str) -> Option<Attribute> {
    // Ruby's lexer drops trailing `# …` comments before `attribute` runs,
    // so the positional type / default never see them. Strip here too
    // (comment-aware : a `#` inside a quoted default is preserved) or the
    // comment leaks into attr_type — the harry_wingate parity drift.
    let line = strip_trailing_comment(line);
    let parts: Vec<&str> = line.splitn(3, ',').collect();
    let first = parts.first()?.trim();

    // Two declaration shapes resolve to the same Attribute IR :
    //
    //   1. Primitive / explicit-name form
    //        attribute :role, String
    //        attribute :role, String, default: "owner"
    //      The first part carries `:name`; extract_symbol picks it up
    //      and parts[1] (if present) is the positional type.
    //
    //   2. i255 bare-VO form (PascalCase value-object as the type-and-
    //      identity)
    //        attribute Role                 → name = "role" (snake_case VO)
    //        attribute Role, as: :role      → name = "role" (explicit alias)
    //      Here the first part has no leading `:` ; the VO name is the
    //      type, and the alias either falls out of `as: :alias` in
    //      parts[1] or defaults to to_snake_case(VO).
    //
    // i479 — without the bare-VO branch, the parser silently drops
    // every `attribute Role, as: :role` line, so any `then_set :role`
    // referencing it tripped check-lifecycle's mutation-reference
    // gate as if the attribute didn't exist.
    let (name, attr_type) = if let Some(sym) = extract_symbol(first) {
        (sym, None)
    } else {
        let vo_name = bare_vo_type(first)?;
        let alias = parts.get(1)
            .and_then(|p| p.find("as:").map(|pos| &p[pos + "as:".len()..]))
            .and_then(extract_symbol)
            .unwrap_or_else(|| to_snake_case(&vo_name));
        (alias, Some(vo_name))
    };

    // Resolve the type from parts[1]. Three cases:
    //   - `list_of(X)`     → extract X, set list=true
    //   - `default: ...`   (or any kwarg) → no positional type, default to "String"
    //   - bare token       → use it as the type (String, Integer, MyValueObject, …)
    let raw = parts.get(1).map(|s| s.trim()).unwrap_or("");
    // Retired 2026-05-12 : Array / Hash bare-types USED to auto-flag
    // list=true (mirroring an old Ruby heuristic). Both heuristics
    // retired together so the parsers agree : collection shape MUST
    // come from `list_of(X)` explicitly. Bluebooks that used bare
    // Array / Hash and meant "scalar collection-shaped attr" stay
    // scalar ; if they meant a list, they now must say `list_of(...)`.
    // `:list_ofs` (substring of "list_of") must NOT register — only
    // `list_of(` with the paren counts.
    let list = line.contains("list_of(");
    let attr_type = if let Some(t) = attr_type {
        // Bare-VO form already pinned the type to the value-object name.
        t
    } else if raw.starts_with("list_of(") {
        let open = raw.find('(')? + 1;
        let close = raw.find(')')?;
        raw[open..close].trim().to_string()
    } else if raw.is_empty() || is_kwarg(raw) {
        "String".to_string()
    } else {
        raw.to_string()
    };

    let required = line.contains("required:")
        && extract_after(line, "required:").map(|a| a.trim_start().starts_with("true")).unwrap_or(false);
    let default = if line.contains("default:") {
        let after = extract_after(line, "default:")?;
        if after.contains('"') { extract_string(&after) }
        else { Some(after.split_whitespace().next().unwrap_or(&after).to_string()) }
    } else { None };
    // one_of scalar sugar (GRAMMAR-one-of, 2026-07-19) :
    //   attribute :standing, one_of("good", "suspended"), default: "good"
    // The quoted values inside the parens are the closed vocabulary ; the
    // storage type is String (mirrors the Ruby collector routing the
    // enum-hash to Structure::Attribute#enum).
    let (attr_type, enum_values) = if let Some(start) = line.find("one_of(") {
        let inner = &line[start + "one_of(".len()..];
        let close = inner.find(')').unwrap_or(inner.len());
        let vals: Vec<String> = inner[..close]
            .split(',')
            .filter_map(extract_string)
            .collect();
        ("String".to_string(), vals)
    } else {
        // The legacy `enum: [...]` kwarg spelling is RETIRED ("enum is too
        // codey" — Chris, 2026-07-19) : all 20 corpus files migrated to
        // one_of the same day. Deliberately NOT parsed here — the Ruby DSL
        // still collects it, so any straggler drifts loudly in parity
        // instead of silently working. The ledger is the guard.
        (attr_type, vec![])
    };
    // `pattern: '<regex>'` — the scalar SHAPE constraint, sibling of one_of's
    // closed vocabulary. Refused here if it uses a construct Ruby and Rust
    // would treat differently, so the divergence never reaches the IR.
    let pattern = parse_pattern_kwarg(line);
    // `hint: "..."` — human guidance surfaced by the form on a shape mismatch.
    // Pure presentation, so it takes no subset check ; it is never a regex.
    let hint = parse_hint_kwarg(line);
    // `logged: false` — keep this attribute's VALUE out of the event Log. Default
    // true : the Log records what happened, so silence is the exception and must
    // be declared. Only the explicit literal `false` excludes ; anything else
    // (including a malformed value) leaves the attribute logged, so a typo fails
    // SAFE — toward recording rather than toward silence.
    let logged = !(line.contains("logged:")
        && extract_after(line, "logged:")
            .map(|a| a.trim_start().starts_with("false"))
            .unwrap_or(false));
    Some(Attribute { name, attr_type, default, list, required, enum_values, pattern, hint, logged })
}

/// Pull `pattern: '<regex>'` (or "double-quoted") off an attribute line.
///
/// A pattern using a construct Ruby and Rust would treat differently is
/// REFUSED here rather than stored — the IR never carries a declaration the
/// two engines would disagree about. The rejection is loud on stderr and the
/// attribute keeps `None`, so a bad pattern fails open (any string) rather
/// than silently enforcing something only one engine understands.
fn parse_pattern_kwarg(line: &str) -> Option<String> {
    let after = line.split("pattern:").nth(1)?.trim_start();
    let quote = after.chars().next().filter(|c| *c == '\'' || *c == '"')?;
    let body: String = after[quote.len_utf8()..]
        .chars()
        .take_while(|c| *c != quote)
        .collect();
    match crate::pattern_subset::validate_pattern_subset(&body) {
        Ok(()) => Some(body),
        Err(rejection) => {
            eprintln!(
                "[bluebook] pattern REFUSED ({}): {}\n  in: {}\n  — {}",
                rejection.construct, body, line.trim(), rejection.reason,
            );
            None
        }
    }
}

/// Pull `hint: "..."` (or 'single-quoted') off an attribute line — the human
/// guidance the form shows when a value fails its shape. Unlike `pattern`, this
/// is prose, never a regex, so it needs no subset check ; it is stored verbatim.
fn parse_hint_kwarg(line: &str) -> Option<String> {
    let after = line.split("hint:").nth(1)?.trim_start();
    let quote = after.chars().next().filter(|c| *c == '"' || *c == '\'')?;
    let body: String = after[quote.len_utf8()..]
        .chars()
        .take_while(|c| *c != quote)
        .collect();
    if body.is_empty() { None } else { Some(body) }
}

/// Pull the PascalCase value-object name from the first segment of a
/// bare-VO `attribute Role` / `attribute Role, as: :alias` line.
/// Returns None for primitive forms (which extract_symbol handles)
/// and for leading tokens that aren't PascalCase.
fn bare_vo_type(first: &str) -> Option<String> {
    let after_kw = first.strip_prefix("attribute")?.trim_start();
    let token: String = after_kw.chars()
        .take_while(|c| c.is_alphanumeric() || *c == '_')
        .collect();
    if token.is_empty() { return None; }
    let mut chars = token.chars();
    let head = chars.next()?;
    if !head.is_uppercase() { return None; }
    Some(token)
}

// A kwarg looks like `key: value` where `key` is a lowercase identifier.
// Distinguishes `default: true` (kwarg) from `String` or `MyVO` (positional type).
fn is_kwarg(s: &str) -> bool {
    let Some(colon_pos) = s.find(':') else { return false; };
    let before = &s[..colon_pos];
    !before.is_empty()
        && before.chars().next().is_some_and(|c| c.is_ascii_lowercase())
        && before.chars().all(|c| c.is_alphanumeric() || c == '_')
}

pub fn parse_fixture(line: &str) -> Fixture {
    let aggregate_name = extract_string(line).unwrap_or_default();
    let mut attributes = vec![];

    // Parse key: <value> pairs after the aggregate name. Values may be
    // strings (with commas inside), arrays, hashes, or numbers — so we
    // split on commas only at the top level (outside "...", [...], {...}).
    //   fixture "Vow", name: "Hi, world", words: "Be transparent."
    if let Some(comma_pos) = line.find(',') {
        let rest = &line[comma_pos + 1..];
        for part in split_top_level_commas(rest) {
            let part = part.trim();
            if let Some(colon) = part.find(':') {
                let key = part[..colon].trim().to_string();
                let raw = part[colon + 1..].trim();
                // For string-literal values, unwrap the quotes; otherwise
                // keep the raw source token (numbers, arrays, hashes, bare).
                let val = if raw.starts_with('"') {
                    extract_string(raw).unwrap_or_else(|| raw.to_string())
                } else {
                    raw.to_string()
                };
                attributes.push((key, val));
            }
        }
    }

    Fixture { name: None, aggregate_name, attributes }
}

/// Parse the body of a block-form fixture. `lines` starts at the line AFTER
/// `fixture "X" do`; parsing stops at the matching `end`. Inside, the
/// `aggregate "X"` line sets the aggregate name; every other `key "value"`
/// line becomes an attribute (string-typed, unwrapped). Returns the parsed
/// fields and the number of lines consumed (including the closing `end`).
pub fn parse_fixture_block_body(lines: &[&str]) -> (String, Vec<(String, String)>, usize) {
    let mut aggregate_name = String::new();
    let mut attributes: Vec<(String, String)> = vec![];
    let mut depth = 1usize;
    let mut i = 0;
    while i < lines.len() && depth > 0 {
        let l = lines[i].trim();
        if l == "end" {
            depth -= 1;
            if depth == 0 { i += 1; break; }
        } else if ends_with_do_block(l) {
            depth += 1;
        } else if depth == 1 && !l.is_empty() && !l.starts_with('#') {
            // First-token dispatch: `aggregate "X"` sets the type; any other
            // identifier `key "value"` (or bare value) becomes an attribute.
            let token_end = l.find(|c: char| c.is_whitespace()).unwrap_or(l.len());
            let key = &l[..token_end];
            let rest = l[token_end..].trim();
            if key == "aggregate" {
                aggregate_name = extract_string(rest).unwrap_or_default();
            } else if !key.is_empty() && key.chars().next().is_some_and(|c| c.is_ascii_lowercase()) {
                let val = if rest.starts_with('"') {
                    extract_string(rest).unwrap_or_else(|| rest.to_string())
                } else {
                    rest.to_string()
                };
                attributes.push((key.to_string(), val));
            }
        }
        i += 1;
    }
    (aggregate_name, attributes, i)
}

// Split on `,` at depth 0 — ignoring commas inside strings, brackets,
// parens, and braces. Used for fixture kwargs and similar comma-separated
// expressions where values can themselves contain commas.
fn split_top_level_commas(s: &str) -> Vec<&str> {
    let mut parts = Vec::new();
    let mut depth = 0i32;
    let mut in_str = false;
    let mut in_single = false;
    let mut start = 0;
    for (i, c) in s.char_indices() {
        match c {
            '"' if !in_single && !escaped_at(s, i) => in_str = !in_str,
            '\'' if !in_str => in_single = !in_single,
            '[' | '{' | '(' if !in_str && !in_single => depth += 1,
            ']' | '}' | ')' if !in_str && !in_single => depth -= 1,
            ',' if !in_str && !in_single && depth == 0 => {
                parts.push(&s[start..i]);
                start = i + 1;
            }
            _ => {}
        }
    }
    parts.push(&s[start..]);
    parts
}

fn escaped_at(s: &str, i: usize) -> bool {
    i > 0 && s.as_bytes().get(i - 1) == Some(&b'\\')
}

pub fn parse_mutation(line: &str) -> Option<Mutation> {
    let field = extract_symbol(line)?;
    let (op, value) = if line.contains("append_unique:") {
        // append iff no value-equal element is already present — idempotent
        // list growth (a re-fired establishment policy re-appends as a no-op).
        (MutationOp::AppendUnique, extract_after(line, "append_unique:")?)
    } else if line.contains("append:") {
        (MutationOp::Append, extract_after(line, "append:")?)
    } else if line.contains("remove:") {
        (MutationOp::Remove, extract_after(line, "remove:")?)
    } else if line.contains("increment:") {
        (MutationOp::Increment, extract_after(line, "increment:")?)
    } else if line.contains("decrement:") {
        (MutationOp::Decrement, extract_after(line, "decrement:")?)
    } else if line.contains("multiply:") {
        // i106 — multiplicative scaling. Value is the f64 factor.
        (MutationOp::Multiply, extract_after(line, "multiply:")?)
    } else if line.contains("clamp:") {
        // i106 — bound a field to [min, max]. Value is the list literal.
        (MutationOp::Clamp, extract_after(line, "clamp:")?)
    } else if line.contains("decay:") {
        // i106 — exponential decay. Value is the rate (0.05 → ×0.95).
        (MutationOp::Decay, extract_after(line, "decay:")?)
    } else if line.contains("to:") {
        (MutationOp::Set, extract_after(line, "to:")?)
    } else if line.contains("from:") {
        // i106 — `then_set :field, from: :param` reads the named command
        // param at dispatch time. We carry the source symbol form
        // (`:param`) so the canonical IR matches Ruby's then_set
        // path : Ruby's mutation_value formats Symbol → ":param", and
        // extract_after returns the raw `:param` token here. Both
        // sides emit `value: ":param"` after canonical normalization.
        (MutationOp::Set, extract_after(line, "from:")?)
    } else {
        // Positional form: `then_set :field, <value>` — value is the
        // token after the field's symbol, separated by a comma.
        let sym_start = line.find(':')? + 1;
        let after_field = &line[sym_start + field.len()..];
        let comma = after_field.find(',')?;
        let raw = after_field[comma + 1..].trim();
        // A bare `<word>:` in the value position is an UNKNOWN mutation op — the
        // known ops are all matched by the `line.contains("<op>:")` branches
        // above, so reaching the positional fallback with a keyword token means
        // a typo (e.g. `upsert:`). Reject it loudly with a hint rather than
        // silently storing the keyword as a Set literal — mirrors the rule-body
        // parser's panic-with-hint rejection, and matches the Ruby DSL's
        // `unknown keyword:` ArgumentError (parity : both runtimes reject it).
        let rb = raw.as_bytes();
        if rb.first().is_some_and(|b| b.is_ascii_lowercase() || *b == b'_') {
            let end = rb.iter()
                .take_while(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || **b == b'_')
                .count();
            if raw[end..].starts_with(':') {
                // Unknown op. DON'T panic — a crash on a typo'd bluebook
                // is a terrible newcomer experience and aborts every
                // reader (CLI validate, dispatch, behaviors). Record the
                // bad op on the Mutation and let the parse complete ;
                // validator_mutations::invalid_mutation_op_errors reports
                // it as a graceful INVALID and interpreter::check_givens
                // refuses to dispatch it. "Reject loudly" is preserved —
                // as a diagnostic, not a stack trace.
                return Some(Mutation {
                    field,
                    operation: MutationOp::Set,
                    value: String::new(),
                    invalid_op: Some(raw[..end].to_string()),
                });
            }
        }
        let value = if let Some(rest) = raw.strip_prefix('"') {
            // Quoted string — strip surrounding quotes.
            let end = rest.find('"')?;
            rest[..end].to_string()
        } else {
            // Bare token — number, true, false, or :symbol.
            raw.split(|c: char| c == ',' || c.is_whitespace())
                .next().unwrap_or("").to_string()
        };
        if value.is_empty() { return None; }
        (MutationOp::Set, value)
    };
    Some(Mutation { field, operation: op, value, invalid_op: None })
}

/// Parse a `process_manager "Name" do … end` block.
///
/// Captures the static shape of the PM (name, correlates_by, starts_on,
/// ends_on, declared states, and per-event handlers with their from→to
/// transition). The action body inside `on "Event", transition: { x: :y }
/// do |event, pm| … end` is intentionally consumed-and-discarded — that
/// proc is Ruby-side execution, not part of the parity contract.
///
/// Form:
///   process_manager "SleepCycle" do
///     correlates_by :body_id
///     starts_on    "SleepStarted"
///     ends_on      "WakeFinished"
///     state "light"
///     state "rem"
///     on "PhaseElapsed", transition: { light: :light } do |event, pm|
///       { commands: ["AdvancePhase"] }
///     end
///   end
///
/// Returns the parsed ProcessManager plus the number of source lines
/// consumed (including the closing `end`).
pub fn parse_process_manager(lines: &[&str]) -> (ProcessManager, usize) {
    let first = lines[0].trim();
    let name = extract_string(first).unwrap_or_default();
    let mut pm = ProcessManager {
        name,
        correlates_by: String::new(),
        starts_on: String::new(),
        ends_on: None,
        states: vec![],
        handlers: vec![],
    };

    let mut i = 1;
    let mut depth = 1usize;
    while i < lines.len() && depth > 0 {
        let line = lines[i].trim();
        if line == "end" {
            depth -= 1;
            if depth == 0 { break; }
            i += 1;
            continue;
        }

        if depth == 1 {
            if line.starts_with("correlates_by") {
                if let Some(sym) = extract_symbol(line) { pm.correlates_by = sym; }
            } else if line.starts_with("starts_on") {
                if let Some(s) = extract_string(line) { pm.starts_on = s; }
            } else if line.starts_with("ends_on") {
                if let Some(s) = extract_string(line) { pm.ends_on = Some(s); }
            } else if line.starts_with("state ") || line.starts_with("state\t") {
                if let Some(s) = extract_string(line) { pm.states.push(s); }
            } else if line.starts_with("on ") || line.starts_with("on\t") {
                let mut handler = parse_pm_handler(line);
                if ends_with_do_block(line) {
                    // Walk the body to its indent-matched closing `end`.
                    // Capture `dispatch "Cmd"` lines as declarative
                    // dispatches ; other body lines (Ruby-proc form,
                    // conditionals, etc.) are still consumed-and-discarded
                    // (opaque to Rust). Phase 2.b
                    // (pm-dispatch-enrichment) glues continuation lines
                    // when a `dispatch ..., with: {` hash spans multiple
                    // lines, so the parser sees one logical dispatch
                    // statement at a time.
                    let on_indent = lines[i].len() - lines[i].trim_start().len();
                    while i + 1 < lines.len() {
                        i += 1;
                        let raw = lines[i];
                        let trimmed = raw.trim();
                        let indent = raw.len() - raw.trim_start().len();
                        if trimmed == "end" && indent == on_indent {
                            break;
                        }
                        if !is_dispatch_start(trimmed) && !is_set_start(trimmed) {
                            continue;
                        }
                        // Glue continuation lines until braces +
                        // parens are balanced (with: hash + sentinel
                        // calls can wrap across multiple lines).
                        let mut joined = trimmed.to_string();
                        while !is_balanced(&joined) && i + 1 < lines.len() {
                            i += 1;
                            joined.push(' ');
                            joined.push_str(lines[i].trim());
                        }
                        if let Some(ref mut h) = handler {
                            if is_dispatch_start(&joined) {
                                if let Some(spec) = parse_dispatch_statement(&joined) {
                                    h.dispatches.push(spec);
                                }
                            } else if is_set_start(&joined) {
                                if let Some((attr, spec)) = parse_set_statement(&joined) {
                                    h.set_specs.push((attr, spec));
                                }
                            }
                        }
                    }
                }
                if let Some(h) = handler { pm.handlers.push(h); }
            } else if ends_with_do_block(line) {
                depth += 1;
            }
        } else if ends_with_do_block(line) {
            depth += 1;
        }

        i += 1;
    }
    (pm, i + 1)
}

/// Parse one `on "Event", transition: { from: :to } do |event, pm|` line
/// into a ProcessManagerHandler. Returns None if the shape is unparseable.
///
/// Source forms recognized :
///   on "Event", transition: { light: :light } do |event, pm|
///   on "Event", transition: { :light => :rem } do |event, pm|
fn parse_pm_handler(line: &str) -> Option<ProcessManagerHandler> {
    let event_type = extract_string(line)?;
    // Pull the `{ … }` after `transition:`. The action's `do |event, pm|`
    // tail comes AFTER the transition hash, so we look for the first
    // `{` and its matching `}` to bound the hash.
    let trans_pos = line.find("transition:")?;
    let after = &line[trans_pos + "transition:".len()..];
    let open = after.find('{')?;
    let close = after[open..].find('}')? + open;
    let body = after[open + 1..close].trim();
    // Body is one of :
    //   `from: :to`        — symbol-rocket sugar
    //   `:from => :to`     — explicit hash-rocket
    // A state may be written as a symbol (`:paid`) or a string (`"paid"`).
    // Both name the SAME state, so both must reduce to the same token —
    // leaving the quotes on would carry source syntax into the IR and make
    // `"paid"` a different state from `:paid`, which is the shape of every
    // parser drift ever retired here.
    let state_token = |raw: &str| {
        raw.trim()
            .trim_end_matches(',')
            .trim()
            .trim_start_matches(':')
            .trim_matches('"')
            .trim()
            .to_string()
    };

    let (from, to) = if body.contains("=>") {
        let mut parts = body.splitn(2, "=>");
        let from = state_token(parts.next()?);
        let to = state_token(parts.next()?);
        (from, to)
    } else {
        let colon = body.find(':')?;
        let from = body[..colon].trim().to_string();
        let rhs = body[colon + 1..].trim().trim_start_matches(':').trim();
        let to = rhs.split(|c: char| c == ',' || c.is_whitespace())
            .next().unwrap_or("").to_string();
        (from, to)
    };
    if from.is_empty() || to.is_empty() { return None; }
    Some(ProcessManagerHandler {
        event_type,
        from_state: from,
        to_state: to,
        dispatches: vec![],
        set_specs: vec![],
    })
}

/// Returns true when `trimmed` starts a `dispatch` statement (used by
/// the on-block walker before it joins continuation lines).
fn is_dispatch_start(trimmed: &str) -> bool {
    trimmed.starts_with("dispatch ")
        || trimmed.starts_with("dispatch\t")
        || trimmed.starts_with("dispatch\"")
}

/// Phase 2.c — returns true when `trimmed` starts a `set` statement
/// inside an on-block. Matches `set :attr, ...` (the Ruby positional
/// form with a Symbol literal) and `set "attr", ...` (string form).
/// The DSL surface today is `set :attr, value_spec` ; the string form
/// is supported defensively. Care taken not to false-match other
/// keywords starting with "set" (e.g. `set_inventory`) by requiring
/// whitespace after.
fn is_set_start(trimmed: &str) -> bool {
    trimmed.starts_with("set ") || trimmed.starts_with("set\t")
}

/// Parse one (possibly glued-multi-line) `set :attr, value_spec` line
/// into an `(attr, ValueSpec)` pair. Three forms recognized for the
/// value : same as the with-spec evaluator (literal / from_event /
/// from_pm). Returns None when the shape is unparseable.
///
///   set :steering_target, from_event(:target)
///   set :carrying, "body"
///   set :tick, from_pm(:tick, default: "0")
fn parse_set_statement(line: &str) -> Option<(String, ValueSpec)> {
    let trimmed = line.trim();
    if !is_set_start(trimmed) { return None; }
    // Drop the leading `set` keyword + whitespace.
    let rest = trimmed[3..].trim_start();
    // Find the first comma at top-level (parens not respected — there
    // shouldn't be any in the attr name).
    let comma = rest.find(',')?;
    let attr_raw = rest[..comma].trim();
    let attr = attr_raw
        .trim_matches(|c| c == '"' || c == '\'' || c == ':')
        .to_string();
    if attr.is_empty() { return None; }
    let val_raw = rest[comma + 1..].trim();
    let spec = parse_value_spec(val_raw)?;
    Some((attr, spec))
}

/// Returns true when every `(`/`)` and `{`/`}` pair in `s` is matched.
/// Used to detect the end of a multi-line `dispatch ..., with: { ... }`
/// statement. Quotes are not respected — a `{` or `(` inside a string
/// would mis-balance. The DSL surface today doesn't put braces in
/// string literals, so this approximation holds ; sources that do
/// would be surfaced as parser drift in parity tests.
fn is_balanced(s: &str) -> bool {
    let mut paren = 0i32;
    let mut brace = 0i32;
    for c in s.chars() {
        match c {
            '(' => paren += 1,
            ')' => paren -= 1,
            '{' => brace += 1,
            '}' => brace -= 1,
            _ => (),
        }
    }
    paren == 0 && brace == 0
}

/// Parse one (possibly glued-multi-line) `dispatch "Cmd"` statement
/// into a structured DispatchSpec. Three source forms recognized :
///
///   dispatch "Aggregate.Command"
///   dispatch "Aggregate.Command", with: { foo: from_event(:bar),
///                                         baz: "lit",
///                                         qux: from_pm(:n, default: "—") }
///   dispatch "Aggregate.Command",
///     for_each: { from: "Aggregate.query_name" },
///     with: { id: from_iter(:id) }
///
/// Returns None when the shape is unparseable. The caller's outer
/// walk skips non-dispatch lines via `is_dispatch_start`, so this
/// function is called only on confirmed dispatch statements.
fn parse_dispatch_statement(line: &str) -> Option<DispatchSpec> {
    let trimmed = line.trim();
    if !is_dispatch_start(trimmed) { return None; }
    let command_name = extract_string(trimmed)?;

    // Find the `with:` and `for_each:` keywords. Tolerant of variable
    // whitespace around the comma (e.g. `dispatch "X",   with: {...}`).
    // The search starts after the closing quote of the command name so
    // a stray `with:` inside the command string can't false-match.
    let cmd_end = match trimmed.match_indices('"').nth(1) {
        Some((idx, _)) => idx + 1,
        None => trimmed.len(),
    };
    let tail = &trimmed[cmd_end..];

    let with_spec = match tail.find("with:") {
        None => Vec::new(),
        Some(pos) => {
            let after = &tail[pos + "with:".len()..];
            let open = after.find('{')?;
            // The matching close brace bounds the with hash. Use a
            // depth counter so nested `from_event(:foo)` parens or any
            // future nested hash don't trip the search.
            let close = match_close_brace(&after[open..])? + open;
            let body = after[open + 1..close].trim();
            parse_with_hash(body)
        }
    };

    // i221-A — sweep dispatch. `for_each: { from: "Aggregate.query" }`
    // splits on the first dot into the two structured halves. Absent
    // `for_each:` leaves `for_each = None` (the back-compat default).
    let for_each = parse_for_each_clause(tail);

    Some(DispatchSpec {
        command_name,
        with_spec,
        for_each,
    })
}

/// i221-A — locate the `for_each: { from: "Aggregate.query_name" }`
/// clause in a dispatch line and lift it to a `ForEachSpec`. Returns
/// `None` when the clause is absent (the common back-compat case) or
/// malformed (no `from:` literal, malformed dotted path, empty parts).
///
/// Two qualified forms accepted :
///   "Aggregate.query_name"            — 2-part (back-compat)
///   "Context.Aggregate.query_name"    — 3-part, disambiguates when
///                                       multiple bluebooks declare
///                                       the same aggregate name (i142
///                                       Context.Aggregate.Command
///                                       resolution applied to query
///                                       lookups too)
pub(crate) fn parse_for_each_clause(tail: &str) -> Option<ForEachSpec> {
    let pos = tail.find("for_each:")?;
    let after = &tail[pos + "for_each:".len()..];
    let open = after.find('{')?;
    let close = match_close_brace(&after[open..])? + open;
    let body = after[open + 1..close].trim();
    // Body shape : `from: "Aggregate.query_name"` (kwarg-shorthand).
    // Hash-rocket form (`:from => "..."`) is not used in the corpus
    // and would be filed as a follow-on.
    let from_pos = body.find("from:")?;
    let value_raw = body[from_pos + "from:".len()..].trim();
    let literal = extract_string(value_raw)?;
    let parts: Vec<&str> = literal.split('.').collect();
    let (mut source_context, mut source_aggregate, query_name) = match parts.as_slice() {
        [agg, qry] if !agg.is_empty() && !qry.is_empty() => {
            (None, agg.to_string(), qry.to_string())
        }
        [ctx, agg, qry] if !ctx.is_empty() && !agg.is_empty() && !qry.is_empty() => {
            (Some(ctx.to_string()), agg.to_string(), qry.to_string())
        }
        _ => return None,
    };
    // i221-C + realm-qualified : accept the dispatch-FQN
    // `[Realm::Context::]Bluebook::Aggregate.query` form (VARIABLE depth) in
    // the aggregate slot. The aggregate is the LAST :: segment, the bluebook
    // context the second-to-last ; the realm / context-folder prefix is
    // matched at resolve time, not here. (The old split_once took the FIRST
    // ::, which mis-parsed a canonical 4-seg ref into a non-existent
    // aggregate — has_query went false and the sweep fell through to the
    // UNFILTERED enumerate-all path, decrementing unrelated records.)
    if source_aggregate.contains("::") {
        let full = source_aggregate.clone();
        let segs: Vec<&str> = full.split("::").collect();
        let n = segs.len();
        source_aggregate = segs[n - 1].to_string();
        source_context = Some(segs[n - 2].to_string());
    }
    // i221-C — optional `where: { input: from_event(:x) }` sub-hash binds
    // the swept query's inputs from the event. Absent = parameterless.
    let query_inputs = match body.find("where:") {
        Some(wp) => {
            let after_w = &body[wp + "where:".len()..];
            match after_w.find('{') {
                Some(o) => {
                    let c = match_close_brace(&after_w[o..])? + o;
                    parse_with_hash(after_w[o + 1..c].trim())
                }
                None => Vec::new(),
            }
        }
        None => Vec::new(),
    };
    Some(ForEachSpec { source_context, source_aggregate, query_name, query_inputs })
}

/// Given a slice that starts at `{`, return the index of the matching
/// `}` (counting depth). Returns None when unmatched. Quotes are not
/// respected — same approximation as `is_balanced`.
fn match_close_brace(s: &str) -> Option<usize> {
    let mut depth = 0i32;
    for (i, c) in s.char_indices() {
        match c {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if depth == 0 { return Some(i); }
            }
            _ => (),
        }
    }
    None
}

/// Parse the inside of a `with: { ... }` hash into an ordered Vec of
/// `(key, ValueSpec)` pairs. Splitting respects nested parens (so
/// `default: "—,"` inside `from_pm(...)` doesn't split), at the cost
/// of not respecting string literals (matches the wider parser
/// surface : an author-supplied literal containing a comma would be
/// surfaced as parity drift).
fn parse_with_hash(body: &str) -> Vec<(String, ValueSpec)> {
    let mut out: Vec<(String, ValueSpec)> = Vec::new();
    for raw_entry in split_top_level_commas(body) {
        let entry = raw_entry.trim().trim_end_matches(',').trim();
        if entry.is_empty() { continue; }
        // `key: value` where key is a bare ident or a quoted string,
        // and value is a literal (string / number) or a sentinel call
        // `from_event(...)` / `from_pm(...)`. A trailing comma after
        // the last entry is tolerated.
        let colon = match entry.find(':') {
            Some(p) => p,
            None => continue,
        };
        // Skip cases where the `:` is part of `=>` or starts a Symbol
        // literal value — for now we only accept the kwarg-shorthand
        // form `key: value`. Hash-rocket form is filed as a follow-up
        // (no PM in the corpus uses it for `with:`).
        let key_raw = entry[..colon].trim();
        let val_raw = entry[colon + 1..].trim();
        let key = key_raw
            .trim_matches(|c| c == '"' || c == '\'' || c == ':')
            .to_string();
        if key.is_empty() { continue; }
        if let Some(spec) = parse_value_spec(val_raw) {
            out.push((key, spec));
        }
    }
    out
}

/// Parse one with-value into a ValueSpec. Four forms :
///
///   "literal"                              → ValueSpec::Literal
///   from_event(:name)                       → FromEvent { default: None }
///   from_event(:name, default: "x")         → FromEvent { default: Some("x") }
///   from_pm(:name)                          → FromPm   { default: None }
///   from_pm(:name, default: "—")            → FromPm   { default: Some("—") }
///   from_iter(:field)                       → FromIter { field } (i221-A)
///
/// Numeric / bare-ident literals are accepted and stringified ; that
/// matches the wider parser convention (canonical IR carries scalars
/// as strings). Returns None on malformed input.
fn parse_value_spec(raw: &str) -> Option<ValueSpec> {
    let s = raw.trim();
    if s.starts_with("from_event") {
        let (name, default) = parse_sentinel_args(s, "from_event")?;
        Some(ValueSpec::FromEvent { name, default })
    } else if s.starts_with("from_pm") {
        let (name, default) = parse_sentinel_args(s, "from_pm")?;
        Some(ValueSpec::FromPm { name, default })
    } else if s.starts_with("from_iter") {
        // i221-A — sweep-iteration sentinel. Reuses parse_sentinel_args
        // for the (name, default) extraction ; the default slot is
        // ignored (FromIter has no default field — sweeps either find
        // the iter record's attribute or the runtime surfaces the miss).
        let (name, _default) = parse_sentinel_args(s, "from_iter")?;
        Some(ValueSpec::FromIter { field: name })
    } else if s.starts_with('"') || s.starts_with('\'') {
        let value = extract_string(s).unwrap_or_default();
        Some(ValueSpec::Literal { value })
    } else {
        // Bare ident / number / symbol — stringify the trimmed token.
        let token = s.trim_end_matches(',').trim().to_string();
        if token.is_empty() {
            return None;
        }
        Some(ValueSpec::Literal { value: token })
    }
}

/// Parse the `(...)` arglist of a sentinel call into (name, default).
/// `name` is required and arrives as `:foo` or `"foo"` ; `default`
/// is optional and named (`default: "..."` form only ; positional
/// not supported).
fn parse_sentinel_args(s: &str, fname: &str) -> Option<(String, Option<String>)> {
    let after = &s[fname.len()..];
    let open = after.find('(')?;
    let close = after[open..].rfind(')')? + open;
    let inner = after[open + 1..close].trim();
    if inner.is_empty() { return None; }

    let parts = split_top_level_commas(inner);
    let mut iter = parts.into_iter();
    let name_raw = iter.next()?.trim().to_string();
    let name = name_raw
        .trim_start_matches(':')
        .trim_matches(|c: char| c == '"' || c == '\'')
        .to_string();
    if name.is_empty() { return None; }

    let mut default: Option<String> = None;
    for rest in iter {
        let r = rest.trim();
        if let Some(rest_after) = r.strip_prefix("default:") {
            let v = rest_after.trim();
            if v.starts_with('"') || v.starts_with('\'') {
                default = extract_string(v);
            } else if !v.is_empty() {
                default = Some(v.trim_end_matches(',').trim().to_string());
            }
        }
    }
    Some((name, default))
}

/// Parse a `cadence "Name" do … end` block declaring scheduled
/// dispatch. i218 — invoked via the block_grammar registry.
///
/// Form :
///   cadence "BodyTick" do
///     every "1s"
///     dispatch "Consciousness.ElapsePhase", name: "consciousness"
///     dispatch "Tick.MindstreamTick",       name: "tick"
///   end
pub fn parse_cadence(lines: &[&str]) -> (Cadence, usize) {
    let first = lines[0].trim();
    let name = extract_string(first).unwrap_or_default();
    let mut cad = Cadence {
        name,
        interval: String::new(),
        dispatches: vec![],
    };

    let mut i = 1;
    let mut depth = 1usize;
    while i < lines.len() && depth > 0 {
        let line = lines[i].trim();
        if line == "end" {
            depth -= 1;
            if depth == 0 { break; }
            i += 1;
            continue;
        }

        if depth == 1 {
            if line.starts_with("every") {
                if let Some(s) = extract_string(line) { cad.interval = s; }
            } else if line.starts_with("dispatch ")
                || line.starts_with("dispatch\t")
                || line.starts_with("dispatch\"")
            {
                if let Some(d) = parse_cadence_dispatch_line(line) {
                    cad.dispatches.push(d);
                }
            } else if ends_with_do_block(line) {
                depth += 1;
            }
        } else if ends_with_do_block(line) {
            depth += 1;
        }

        i += 1;
    }
    (cad, i + 1)
}

/// Parse one `dispatch "Aggregate.Command", k1: v1, k2: v2` line into
/// a CadenceDispatch. Captures the qualified command name and an
/// ordered (key, source-text-value) attribute list. Returns None when
/// the line isn't a dispatch line.
pub fn parse_cadence_dispatch_line(line: &str) -> Option<CadenceDispatch> {
    let trimmed = line.trim();
    let command_name = extract_string(trimmed)?;
    let q1 = trimmed.find('"')?;
    let q2 = trimmed[q1 + 1..].find('"')? + q1 + 1;
    let after = trimmed[q2 + 1..].trim();
    let mut attrs: Vec<(String, String)> = Vec::new();
    if let Some(rest) = after.strip_prefix(',') {
        let kwargs = rest.trim();
        attrs = split_top_level_cadence(kwargs)
            .into_iter()
            .filter_map(|pair| {
                let p = pair.trim();
                let colon = p.find(':')?;
                let key = p[..colon].trim().trim_matches(':').to_string();
                let value = p[colon + 1..].trim().to_string();
                if key.is_empty() || value.is_empty() { None } else { Some((key, value)) }
            })
            .collect();
    }
    Some(CadenceDispatch { command_name, attrs })
}

/// Split a kwarg list on top-level commas only — bracket / brace /
/// paren / string contents are protected. Cadence-local helper.
fn split_top_level_cadence(s: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let mut buf = String::new();
    let mut depth: i32 = 0;
    let mut in_str = false;
    let mut prev = '\0';
    for c in s.chars() {
        match c {
            '"' if prev != '\\' => { in_str = !in_str; buf.push(c); }
            '[' | '{' | '(' if !in_str => { depth += 1; buf.push(c); }
            ']' | '}' | ')' if !in_str => { depth -= 1; buf.push(c); }
            ',' if !in_str && depth == 0 => {
                out.push(buf.trim().to_string());
                buf.clear();
            }
            _ => buf.push(c),
        }
        prev = c;
    }
    if !buf.trim().is_empty() { out.push(buf.trim().to_string()); }
    out
}
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
        if let Some(tail) = line.strip_prefix("requires") {
            let after = &tail.trim_start();
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

/// Parse a `view "name" do ... end` block at aggregate scope (i254).
///
/// Lines inside the block are recognized as :
///
///   * `show :a, :b, :c`  — append the listed symbols to `fields`
///   * `show_all`         — set `show_all = true` (admin-style projection)
///   * `plus :x, :y`      — append the listed symbols to `fields`
///                          (typically used after `show_all`)
///
/// Other lines are absorbed silently so that future view sub-DSL (e.g.
/// `show ServiceAddress.gate_code, as: :gate_code` from i254's full
/// proposal) doesn't crash the parser before we wire it into the IR.
pub fn parse_view(lines: &[&str]) -> (View, usize) {
    let first = lines[0].trim();
    let name = extract_string(first).unwrap_or_default();
    let mut v = View { name, show_all: false, fields: vec![] };

    let mut i = 1;
    let mut depth = 1;
    while i < lines.len() && depth > 0 {
        let line = lines[i].trim();
        if line == "end" {
            depth -= 1;
            if depth == 0 { break; }
            i += 1;
            continue;
        }
        if depth == 1 {
            if line == "show_all" || line.starts_with("show_all ") {
                v.show_all = true;
            } else if line.starts_with("show") || line.starts_with("plus") {
                // Glue continuation lines : `show :a,\n     :b,\n     :c` is
                // one logical statement. Walk forward while the current line
                // ends with a comma, joining tails into one buffer before
                // splitting. The keyword prefix is stripped once at the head.
                let mut buf = String::new();
                // `show` and `plus` are both four characters, so ONE strip
                // length serves either head — this was a two-armed `if` whose
                // arms both returned 4, which read like a bug and is not one.
                let head_keyword_len = 4;
                buf.push_str(&line[head_keyword_len..]);
                while buf.trim_end().ends_with(',') && i + 1 < lines.len() {
                    i += 1;
                    buf.push(' ');
                    buf.push_str(lines[i].trim());
                }
                absorb_view_fields(&buf, &mut v.fields);
            } else if ends_with_do_block(line) {
                depth += 1;
            }
        } else if ends_with_do_block(line) {
            depth += 1;
        }
        i += 1;
    }
    (v, i + 1)
}

/// Pull `:sym, :sym, :sym` off a tail fragment from a `show` / `plus`
/// line, appending each symbol-name as a string into `fields`. Only
/// `:symbol` tokens are captured ; cross-aggregate join tokens like
/// `ServiceAddress.gate_code` (i249-tied) are ignored at the IR level
/// pending the references-in-views card. Tolerates trailing commas +
/// whitespace.
fn absorb_view_fields(tail: &str, fields: &mut Vec<String>) {
    for raw in tail.split(',') {
        let part = raw.trim().trim_end_matches(',').trim();
        if part.is_empty() { continue; }
        // Skip kwarg-style tail tokens like `as: :foo` — first segment
        // ends with `:` so we treat that whole segment as non-field.
        if part.ends_with(':') { continue; }
        // Only `:symbol` tokens are first-class own-field projections.
        if !part.starts_with(':') { continue; }
        let name = part.trim_start_matches(':').to_string();
        if !name.is_empty() {
            fields.push(name);
        }
    }
}

/// Parse an aggregate-level `invariant "name" do holds_when { <pred> } end`
/// block (f4). The first line carries the rule name (a quoted string) ; the
/// `holds_when { ... }` line inside carries the predicate, extracted with the
/// same `{ ... }` block grammar a single-line `given` uses. Returns the
/// parsed Invariant (None when the name or predicate is missing/unparseable)
/// plus the number of source lines consumed including the closing `end`.
///
/// Form:
///   invariant "ready_means_verified" do
///     holds_when { state != "done" || verified == true }
///   end
///
/// Predicates are single-line — the same constraint a `given` carries, since
/// both flow through the same line-scanning expression grammar.
pub fn parse_invariant(lines: &[&str]) -> (Option<Invariant>, usize) {
    let first = lines[0].trim();
    let name = extract_string(first).unwrap_or_default();
    let mut expression: Option<String> = None;
    let mut i = 1;
    let mut depth = 1usize;
    while i < lines.len() && depth > 0 {
        let line = lines[i].trim();
        if line == "end" {
            depth -= 1;
            if depth == 0 { break; }
            i += 1;
            continue;
        }
        if depth == 1 && line.starts_with("holds_when") {
            expression = extract_block(line);
        } else if ends_with_do_block(line) {
            depth += 1;
        }
        i += 1;
    }
    let consumed = i + 1;
    match (name.is_empty(), expression) {
        (false, Some(expr)) => (Some(Invariant { name, expression: expr }), consumed),
        _ => (None, consumed),
    }
}


#[cfg(test)]
mod dispatch_tests {
    use super::*;

    #[test]
    fn parses_bare_dispatch() {
        let s = parse_dispatch_statement(r#"dispatch "Body.WakeUp""#).unwrap();
        assert_eq!(s.command_name, "Body.WakeUp");
        assert!(s.with_spec.is_empty());
    }

    #[test]
    fn parses_dispatch_with_literal_and_from_event() {
        let line = r#"dispatch "Body.Tick", with: { name: "body", tick: from_event(:tick) }"#;
        let s = parse_dispatch_statement(line).unwrap();
        assert_eq!(s.command_name, "Body.Tick");
        assert_eq!(s.with_spec.len(), 2);
        assert_eq!(s.with_spec[0].0, "name");
        assert!(matches!(s.with_spec[0].1, ValueSpec::Literal { ref value } if value == "body"));
        assert_eq!(s.with_spec[1].0, "tick");
        assert!(matches!(s.with_spec[1].1, ValueSpec::FromEvent { ref name, default: None } if name == "tick"));
    }

    #[test]
    fn parses_from_pm_with_default() {
        let line = r#"dispatch "X.Y", with: { carrying: from_pm(:carrying, default: "—") }"#;
        let s = parse_dispatch_statement(line).unwrap();
        assert_eq!(s.with_spec.len(), 1);
        match &s.with_spec[0].1 {
            ValueSpec::FromPm { name, default } => {
                assert_eq!(name, "carrying");
                assert_eq!(default.as_deref(), Some("—"));
            }
            other => panic!("expected FromPm, got {:?}", other),
        }
    }

    #[test]
    fn tolerates_variable_whitespace_around_with() {
        let line = r#"dispatch "X.Y",          with: { tick: from_event(:tick) }"#;
        let s = parse_dispatch_statement(line).unwrap();
        assert_eq!(s.with_spec.len(), 1);
        assert_eq!(s.with_spec[0].0, "tick");
    }

    #[test]
    fn preserves_with_declaration_order() {
        let line = r#"dispatch "X.Y", with: { a: 1, b: 2, c: 3 }"#;
        let s = parse_dispatch_statement(line).unwrap();
        assert_eq!(s.with_spec.iter().map(|(k, _)| k.as_str()).collect::<Vec<_>>(), vec!["a", "b", "c"]);
    }

    // ---- Phase 2.c — `set :attr, value_spec` parser tests ----------

    #[test]
    fn is_set_start_distinguishes_set_directive() {
        assert!(is_set_start("set :carrying, \"body\""));
        assert!(is_set_start("set\t:tick, from_event(:tick)"));
        // Don't match other identifiers that happen to begin with "set".
        assert!(!is_set_start("set_inventory :foo"));
        assert!(!is_set_start("settings :foo"));
        // Don't match dispatch (the existing keyword).
        assert!(!is_set_start("dispatch \"X.Y\""));
    }

    #[test]
    fn parses_set_with_literal() {
        let (attr, spec) = parse_set_statement(r#"set :carrying, "body""#).unwrap();
        assert_eq!(attr, "carrying");
        assert!(matches!(spec, ValueSpec::Literal { ref value } if value == "body"));
    }

    #[test]
    fn parses_set_with_from_event() {
        let (attr, spec) = parse_set_statement(r#"set :steering_target, from_event(:target)"#).unwrap();
        assert_eq!(attr, "steering_target");
        match spec {
            ValueSpec::FromEvent { name, default } => {
                assert_eq!(name, "target");
                assert!(default.is_none());
            }
            other => panic!("expected FromEvent, got {:?}", other),
        }
    }

    #[test]
    fn parses_set_with_from_pm_and_default() {
        let (attr, spec) =
            parse_set_statement(r#"set :tick, from_pm(:tick, default: "0")"#).unwrap();
        assert_eq!(attr, "tick");
        match spec {
            ValueSpec::FromPm { name, default } => {
                assert_eq!(name, "tick");
                assert_eq!(default.as_deref(), Some("0"));
            }
            other => panic!("expected FromPm, got {:?}", other),
        }
    }

    #[test]
    fn parses_set_with_string_attr_form() {
        // Defensive : the DSL surface is :attr (Symbol) but the parser
        // also tolerates the string form for hand-built fixtures.
        let (attr, spec) = parse_set_statement(r#"set "carrying", "body""#).unwrap();
        assert_eq!(attr, "carrying");
        assert!(matches!(spec, ValueSpec::Literal { ref value } if value == "body"));
    }

    #[test]
    fn rejects_malformed_set_lines() {
        // No comma — can't tell attr from value.
        assert!(parse_set_statement("set :carrying").is_none());
        // Empty attribute name after stripping :,",'
        assert!(parse_set_statement(r#"set :, "body""#).is_none());
        // Not a set line at all.
        assert!(parse_set_statement(r#"dispatch "X.Y""#).is_none());
    }

    // ---- i221-A — `for_each:` + `from_iter(:field)` parser tests ----

    #[test]
    fn parses_bare_dispatch_carries_no_for_each() {
        let s = parse_dispatch_statement(r#"dispatch "Body.WakeUp""#).unwrap();
        assert!(s.for_each.is_none(), "bare dispatch must leave for_each None");
    }

    #[test]
    fn parses_dispatch_for_each_into_qualified_halves() {
        let line = r#"dispatch "Synapse.Compost", for_each: { from: "Synapse.cold" }, with: { id: from_iter(:id) }"#;
        let s = parse_dispatch_statement(line).unwrap();
        assert_eq!(s.command_name, "Synapse.Compost");
        let fe = s.for_each.as_ref().expect("for_each parsed");
        assert_eq!(fe.source_aggregate, "Synapse");
        assert_eq!(fe.query_name, "cold");
        assert_eq!(s.with_spec.len(), 1);
        assert_eq!(s.with_spec[0].0, "id");
        match &s.with_spec[0].1 {
            ValueSpec::FromIter { field } => assert_eq!(field, "id"),
            other => panic!("expected FromIter, got {:?}", other),
        }
    }

    #[test]
    fn parses_dispatch_for_each_only_no_with() {
        let line = r#"dispatch "Synapse.Compost", for_each: { from: "Synapse.cold" }"#;
        let s = parse_dispatch_statement(line).unwrap();
        let fe = s.for_each.as_ref().expect("for_each parsed");
        assert_eq!(fe.source_aggregate, "Synapse");
        assert_eq!(fe.query_name, "cold");
        assert!(s.with_spec.is_empty());
        assert!(fe.query_inputs.is_empty(), "no where: -> empty query_inputs");
    }

    #[test]
    fn parses_for_each_where_binds_query_inputs_from_event() {
        // i221-C where-fan-out : the swept query is parameterised by the
        // triggering event so it filters (leases held by THIS worker).
        let line = r#"dispatch "Conductor::Lease.Reclaim", for_each: { from: "Conductor::Lease.HeldByWorker", where: { worker: from_event(:worker) } }, with: { id: from_iter(:worktree_path) }"#;
        let s = parse_dispatch_statement(line).unwrap();
        let fe = s.for_each.as_ref().expect("for_each parsed");
        assert_eq!(fe.source_context.as_deref(), Some("Conductor"));
        assert_eq!(fe.source_aggregate, "Lease");
        assert_eq!(fe.query_name, "HeldByWorker");
        assert_eq!(fe.query_inputs.len(), 1);
        assert_eq!(fe.query_inputs[0].0, "worker");
        match &fe.query_inputs[0].1 {
            ValueSpec::FromEvent { name, .. } => assert_eq!(name, "worker"),
            other => panic!("expected FromEvent, got {:?}", other),
        }
        assert_eq!(s.with_spec.len(), 1);
        match &s.with_spec[0].1 {
            ValueSpec::FromIter { field } => assert_eq!(field, "worktree_path"),
            other => panic!("expected FromIter, got {:?}", other),
        }
    }

    #[test]
    fn parses_from_iter_value_spec_in_isolation() {
        let spec = parse_value_spec("from_iter(:strength)").unwrap();
        match spec {
            ValueSpec::FromIter { field } => assert_eq!(field, "strength"),
            other => panic!("expected FromIter, got {:?}", other),
        }
    }

    #[test]
    fn for_each_clause_rejects_unqualified_literal() {
        // No dot — can't split into source_aggregate / query_name.
        let line = r#"dispatch "X.Y", for_each: { from: "cold" }"#;
        let s = parse_dispatch_statement(line).unwrap();
        // Malformed for_each is filtered to None, dispatch still parses
        // (the receiving aggregate command name is still valid).
        assert!(s.for_each.is_none());
    }

    #[test]
    fn parse_process_manager_captures_for_each_dispatch() {
        let src = r#"process_manager "P" do
  correlates_by :id
  starts_on "Started"
  state "rem"
  on "Beat", transition: { rem: :rem } do
    dispatch "Synapse.Compost", for_each: { from: "Synapse.cold" }, with: { id: from_iter(:id) }
  end
end
"#;
        let lines: Vec<&str> = src.lines().collect();
        let (pm, _consumed) = parse_process_manager(&lines);
        assert_eq!(pm.handlers.len(), 1);
        let h = &pm.handlers[0];
        assert_eq!(h.dispatches.len(), 1);
        let d = &h.dispatches[0];
        let fe = d.for_each.as_ref().expect("for_each captured");
        assert_eq!(fe.source_aggregate, "Synapse");
        assert_eq!(fe.query_name, "cold");
    }

    #[test]
    fn parse_process_manager_captures_set_specs_in_declaration_order() {
        // Block-shape mirrors the synthetic 20_process_manager fixture's
        // `on "TargetSighted"` handler. The parser must collect three
        // set entries in source order, all on the same handler.
        let src = r#"process_manager "P" do
  correlates_by :id
  starts_on "Started"
  state "rem"
  on "TargetSighted", transition: { rem: :rem } do
    set :steering_target, from_event(:target)
    set :carrying, "body"
    set :tick, from_pm(:tick, default: "0")
    dispatch "Body.Steer", with: { target: from_pm(:steering_target) }
  end
end
"#;
        let lines: Vec<&str> = src.lines().collect();
        let (pm, _consumed) = parse_process_manager(&lines);
        assert_eq!(pm.handlers.len(), 1);
        let h = &pm.handlers[0];
        assert_eq!(h.event_type, "TargetSighted");
        assert_eq!(
            h.set_specs.iter().map(|(k, _)| k.as_str()).collect::<Vec<_>>(),
            vec!["steering_target", "carrying", "tick"]
        );
        // The third entry is the from_pm(:tick, default: "0") form.
        match &h.set_specs[2].1 {
            ValueSpec::FromPm { name, default } => {
                assert_eq!(name, "tick");
                assert_eq!(default.as_deref(), Some("0"));
            }
            other => panic!("expected FromPm, got {:?}", other),
        }
        // Dispatches still parsed alongside set_specs on the same handler.
        assert_eq!(h.dispatches.len(), 1);
        assert_eq!(h.dispatches[0].command_name, "Body.Steer");
    }
}
