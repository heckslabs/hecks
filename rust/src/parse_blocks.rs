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
/// Forms recognized (all eq op for now ; richer ops follow as fixtures
/// demand them) :
///   where field: value           (hash form, eq)
///   where(field: value)          (parenthesized hash form, eq)
///   where field1: v1, field2: v2 (multi-pair, all eq)
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
    for part in body.split(',') {
        let part = part.trim();
        if part.is_empty() { continue; }
        if let Some(colon) = part.find(':') {
            let field = part[..colon].trim().to_string();
            let raw = part[colon + 1..].trim();
            if field.is_empty() { continue; }
            let value = if raw.starts_with('"') {
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
            };
            out.push(WhereClause {
                field,
                op: WhereOp::Eq,
                value,
            });
        }
    }
    out
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
                if let Some(h) = parse_pm_handler(line) { pm.handlers.push(h); }
                if ends_with_do_block(line) {
                    // Skip the action body — Ruby-side execution. Use
                    // indentation matching : the closing `end` of the
                    // `on ... do` block is at the same column as `on`.
                    // Tracking by `do`-counter alone breaks because Ruby
                    // action bodies use `if/else/end`, `case/end`, etc. ;
                    // those `end`s are NOT the do/end's close. Indentation
                    // is the cleanest discriminator the canonical bluebook
                    // formatting respects.
                    let on_indent = lines[i].len() - lines[i].trim_start().len();
                    while i + 1 < lines.len() {
                        i += 1;
                        let raw = lines[i];
                        let trimmed = raw.trim();
                        let indent = raw.len() - raw.trim_start().len();
                        if trimmed == "end" && indent == on_indent {
                            break;
                        }
                    }
                }
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
    Some(ProcessManagerHandler { event_type, from_state: from, to_state: to })
}
