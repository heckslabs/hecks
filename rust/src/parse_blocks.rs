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
        references: vec![], emits: None, givens: vec![], mutations: vec![],
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

        if ends_with_do_block(line) {
            if depth > 1 || (!line.starts_with("attribute")
                && !line.starts_with("role")
                && !line.starts_with("given")
                && !line.starts_with("then_"))
            {
                depth += 1;
                i += 1;
                continue;
            }
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
                cmd.role = extract_string(line);
            } else if line.starts_with("goal") || line.starts_with("description") {
                cmd.description = extract_string(line);
            } else if line.starts_with("emits") {
                cmd.emits = extract_string(line);
            } else if line.starts_with("reference_to") {
                if let Some(target) = extract_word_after(line, "reference_to") {
                    let snake = to_snake_case(&target);
                    cmd.references.push(Reference { name: snake, target, domain: None });
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
                    cmd.mutations.push(Mutation { field, operation: MutationOp::Toggle, value: String::new() });
                }
            } else if line.starts_with("then_delete") {
                // Record-level deletion. No field, no value — the op
                // alone says "remove this aggregate after dispatch".
                cmd.mutations.push(Mutation {
                    field: String::new(),
                    operation: MutationOp::Delete,
                    value: String::new(),
                });
            }
        }
        i += 1;
    }
    (cmd, i + 1)
}

fn parse_inline_command(line: &str, cmd: &mut Command) {
    if let Some(block) = extract_block(line) {
        for part in block.split(';') {
            let part = part.trim();
            if part.starts_with("role") {
                cmd.role = extract_string(part);
            } else if part.starts_with("emits") {
                cmd.emits = extract_string(part);
            } else if part.starts_with("attribute") {
                if let Some(attr) = parse_attribute(part) { cmd.attributes.push(attr); }
            } else if part.starts_with("reference_to") {
                if let Some(target) = extract_word_after(part, "reference_to") {
                    let snake = to_snake_case(&target);
                    cmd.references.push(Reference { name: snake, target, domain: None });
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

pub fn parse_value_object(lines: &[&str]) -> (ValueObject, usize) {
    let first = lines[0].trim();
    let name = extract_string(first).unwrap_or_default();
    let mut vo = ValueObject { name, description: None, attributes: vec![] };

    let mut i = 1;
    let mut depth = 1;
    while i < lines.len() && depth > 0 {
        let line = lines[i].trim();
        if line == "end" {
            depth -= 1;
            if depth == 0 { break; }
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

    let mut i = 1;
    while i < lines.len() {
        let line = lines[i].trim();
        if line == "end" { break; }
        if line.starts_with("on") { on_event = extract_string(line).unwrap_or_default(); }
        if line.starts_with("trigger") { trigger = extract_string(line).unwrap_or_default(); }
        if line.starts_with("across") { target_domain = extract_string(line); }
        i += 1;
    }
    (Policy { name, on_event, trigger_command: trigger, target_domain }, i + 1)
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
    let parts: Vec<&str> = line.splitn(3, ',').collect();
    let first = parts.first()?.trim();
    let name = extract_symbol(first)?;

    // Resolve the type from parts[1]. Three cases:
    //   - `list_of(X)`     → extract X, set list=true
    //   - `default: ...`   (or any kwarg) → no positional type, default to "String"
    //   - bare token       → use it as the type (String, Integer, MyValueObject, …)
    let raw = parts.get(1).map(|s| s.trim()).unwrap_or("");
    // `list_of(X)` is the explicit collection form. `Array` and `Hash`
    // as bare types are also collection-shaped (Ruby DSL treats them
    // as list:true). `:list_ofs` (substring of "list_of") must NOT
    // register — only `list_of(` with the paren counts.
    let list = line.contains("list_of(") || raw == "Array" || raw == "Hash";
    let attr_type = if raw.starts_with("list_of(") {
        let open = raw.find('(')? + 1;
        let close = raw.find(')')?;
        raw[open..close].trim().to_string()
    } else if raw.is_empty() || is_kwarg(raw) {
        "String".to_string()
    } else {
        raw.to_string()
    };

    let default = if line.contains("default:") {
        let after = extract_after(line, "default:")?;
        if after.contains('"') { extract_string(&after) }
        else { Some(after.split_whitespace().next().unwrap_or(&after).to_string()) }
    } else { None };
    Some(Attribute { name, attr_type, default, list })
}

// A kwarg looks like `key: value` where `key` is a lowercase identifier.
// Distinguishes `default: true` (kwarg) from `String` or `MyVO` (positional type).
fn is_kwarg(s: &str) -> bool {
    let Some(colon_pos) = s.find(':') else { return false; };
    let before = &s[..colon_pos];
    !before.is_empty()
        && before.chars().next().map_or(false, |c| c.is_ascii_lowercase())
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
            } else if !key.is_empty() && key.chars().next().map_or(false, |c| c.is_ascii_lowercase()) {
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
    let mut start = 0;
    for (i, c) in s.char_indices() {
        match c {
            '"' if !escaped_at(s, i) => in_str = !in_str,
            '[' | '{' | '(' if !in_str => depth += 1,
            ']' | '}' | ')' if !in_str => depth -= 1,
            ',' if !in_str && depth == 0 => {
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
    let (op, value) = if line.contains("append:") {
        (MutationOp::Append, extract_after(line, "append:")?)
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
        let value = if raw.starts_with('"') {
            // Quoted string — strip surrounding quotes.
            let end = raw[1..].find('"').map(|i| i + 1)?;
            raw[1..end].to_string()
        } else {
            // Bare token — number, true, false, or :symbol.
            raw.split(|c: char| c == ',' || c.is_whitespace())
                .next().unwrap_or("").to_string()
        };
        if value.is_empty() { return None; }
        (MutationOp::Set, value)
    };
    Some(Mutation { field, operation: op, value })
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
    let (from, to) = if body.contains("=>") {
        let mut parts = body.splitn(2, "=>");
        let lhs = parts.next()?.trim();
        let rhs = parts.next()?.trim();
        let from = lhs.trim_start_matches(':').trim_end_matches(',').trim().to_string();
        let to = rhs.trim_start_matches(':').trim().to_string();
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
/// malformed (no `from:` literal, no qualifying dot, empty halves).
fn parse_for_each_clause(tail: &str) -> Option<ForEachSpec> {
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
    // Two qualified forms accepted :
    //   "Aggregate.query_name"            (2-part, back-compat)
    //   "Context.Aggregate.query_name"    (3-part — disambiguates when
    //                                      multiple bluebooks declare
    //                                      the same aggregate name ;
    //                                      i142 Context.Aggregate.Command
    //                                      resolution applied to query
    //                                      lookups too)
    // Splitting on '.' : 2 parts → source_context = None ;
    // 3 parts → source_context = Some(parts[0]).
    let parts: Vec<&str> = literal.split('.').collect();
    let (source_context, source_aggregate, query_name) = match parts.as_slice() {
        [agg, qry] if !agg.is_empty() && !qry.is_empty() => {
            (None, agg.to_string(), qry.to_string())
        }
        [ctx, agg, qry] if !ctx.is_empty() && !agg.is_empty() && !qry.is_empty() => {
            (Some(ctx.to_string()), agg.to_string(), qry.to_string())
        }
        _ => return None,
    };
    Some(ForEachSpec { source_context, source_aggregate, query_name })
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
