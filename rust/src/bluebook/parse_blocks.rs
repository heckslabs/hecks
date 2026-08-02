use crate::ir::*;
use crate::parser_helpers::*;

pub fn parse_read_model(lines: &[&str]) -> (ReadModel, usize) {
    let first = lines[0].trim();
    let mut model = ReadModel {
        name: extract_string(first).unwrap_or_default(),
        description: None,
        reference_name: String::new(),
        reference_target: String::new(),
        aggregate_heads: vec![],
        offset: None,
        cursor: None,
        consistency: None,
        freshness: None,
        authorization: None,
        null_semantics: None,
        inspection: None,
        index_hints: vec![],
    };
    if !ends_with_do_block(first) { return (model, 1); }
    let mut i = 1;
    while i < lines.len() {
        let line = lines[i].trim();
        if line == "end" { break; }
        if line.starts_with("description") { model.description = extract_string(line); }
        if line.starts_with("reference_to") {
            model.reference_target = extract_word_after(line, "reference_to").unwrap_or_default();
            model.reference_name = line.find("as:").and_then(|pos| extract_symbol(&line[pos + 3..]))
                .unwrap_or_else(|| crate::naming::snake(&model.reference_target));
        }
        if line.starts_with("include ") {
            if let Some(aggregate) = extract_word_after(line, "include") {
                let many = aggregate != model.reference_target;
                let name = line.find("as:").and_then(|pos| extract_symbol(&line[pos + 3..]))
                    .unwrap_or_else(|| {
                        let singular = crate::naming::snake(&aggregate);
                        if many { crate::naming::plural(&singular) } else { singular }
                    });
                model.aggregate_heads.push(AggregateHead { aggregate, r#as: name, many });
            }
        }
        apply_option_line(
            line,
            &mut model.offset,
            &mut model.cursor,
            &mut model.consistency,
            &mut model.freshness,
            &mut model.authorization,
            &mut model.null_semantics,
            &mut model.inspection,
            &mut model.index_hints,
        );
        i += 1;
    }
    (model, i + 1)
}

/// `owner` is the aggregate or entity this command hangs off — the parser needs
/// it to tell the ROOT a command acts on from a reference-typed ARGUMENT, which
/// is a distinction only the owner's own name can settle. See `settle_references`.
pub fn parse_command(lines: &[&str], owner: &str) -> (Command, usize) {
    let first = lines[0].trim();
    let name = extract_string(first)
        .unwrap_or_else(|| first.split_whitespace().next().unwrap_or("").to_string());

    let mut cmd = Command {
        name,
        goal: None,
        role: None,
        attributes: vec![],
        references: None,
        emits: vec![],
        givens: vec![],
        mutations: vec![],
    };
    if first.contains("{") && first.contains("}") {
        parse_inline_command(first, &mut cmd);
        settle_references(&mut cmd, owner);
        return (cmd, 1);
    }

    if !ends_with_do_block(first) {
        return (cmd, 1);
    }

    let mut i = 1;
    let mut depth = 1;

    while i < lines.len() && depth > 0 {
        let line = lines[i].trim();

        if line == "end" {
            depth -= 1;
            if depth == 0 {
                break;
            }
            i += 1;
            continue;
        }

        if ends_with_do_block(line)
            && (depth > 1
                || (!line.starts_with("attribute")
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
                if let Some(attr) = parse_attribute(line) {
                    cmd.attributes.push(attr);
                }
            } else if line.starts_with("role") {
                cmd.role = parse_role_arg(line);
            } else if line.starts_with("goal") {
                cmd.goal = extract_string(line);
            } else if line.starts_with("emits") {
                cmd.emits.extend(extract_string(line));
            } else if line.starts_with("reference_to") {
                if let Some(target) = extract_word_after(line, "reference_to") {
                    let name = if let Some(pos) = line.find(", as:") {
                        let after = &line[pos + ", as:".len()..];
                        extract_symbol(after).unwrap_or_else(|| format!("{}_id", crate::naming::snake(&target)))
                    } else {
                        format!("{}_id", crate::naming::snake(&target))
                    };
                    // THE ONE ARGUMENT `Command#reference_to` TAKES THAT AN
                    // AGGREGATE'S OWN NEVER DOES : a cross-referenced argument
                    // may or may not be given, same as any other attribute a
                    // command declares (CommandBuilder#reference_to's
                    // `optional:`). Left unread until this pass — nothing in
                    // the corpus has exercised it yet, but the language
                    // declares it (Command.reference_to's `optional:` row in
                    // syntax.bluebook) and Ruby honors it.
                    let optional = line.contains("optional:")
                        && extract_after(line, "optional:")
                            .map(|a| a.trim_start().starts_with("true"))
                            .unwrap_or(false);
                    cmd.attributes.push(reference_attribute(name, &target, optional));
                }
            } else if line.starts_with("given") && line.contains(" do ") && line.ends_with("end") {
                let msg = extract_string(line);
                if let (Some(do_pos), Some(stripped)) =
                    (inline_do_pos(line), line.strip_suffix("end"))
                {
                    let expr = stripped[do_pos + " do ".len()..].trim().to_string();
                    if !expr.is_empty() {
                        cmd.givens.push(Given {
                            canonical: expr,
                            description: msg,
                        });
                    }
                }
            } else if line.starts_with("given") && ends_with_do_block(line) {
                let msg = extract_string(line);
                let mut body: Vec<&str> = Vec::new();
                let mut j = i + 1;
                let mut d = 1;
                while j < lines.len() && d > 0 {
                    let l = lines[j].trim();
                    if ends_with_do_block(l) {
                        d += 1;
                    }
                    if l == "end" {
                        d -= 1;
                        if d == 0 {
                            break;
                        }
                    }
                    if !l.is_empty() && !l.starts_with('#') {
                        body.push(l);
                    }
                    j += 1;
                }
                let expr = join_predicate_lines(&body);
                if !expr.is_empty() {
                    cmd.givens.push(Given {
                        canonical: expr,
                        description: msg,
                    });
                }
                i = j + 1;
                continue;
            } else if line.starts_with("given") {
                let block = extract_block(line);
                let line_no_block = match line.find('{') {
                    Some(open) => &line[..open],
                    None => line,
                };
                let msg = extract_string(line_no_block);
                let expr = block.unwrap_or_else(|| msg.clone().unwrap_or_default());
                cmd.givens.push(Given {
                    canonical: expr,
                    description: msg,
                });
            } else if line.starts_with("then_set") {
                if let Some(m) = parse_mutation(line) {
                    cmd.mutations.push(m);
                }
            }
        }
        i += 1;
    }
    settle_references(&mut cmd, owner);
    (cmd, i + 1)
}

/// UNTANGLE THE ROOT FROM THE ARGUMENTS, once, at parse time.
///
/// `reference_to` is one word in the language for two things: the aggregate a
/// command acts ON, and an argument that happens to hold another aggregate's
/// id. Ruby keeps them apart in the IR — `references` is a scalar, arguments
/// are attributes — so Rust settles it here rather than re-deriving it every
/// time the IR is projected.
///
/// Every reference that reads as the acted-on root is dropped from the
/// arguments, and its presence names the root. The survivors stay exactly where
/// they were WRITTEN.
///
/// They used to be gathered into a side vector and PREPENDED, with a comment
/// claiming that was "the order the IR has always carried". It was not — Ruby
/// keeps declaration order, and the two only agreed because every command in the
/// corpus happened to declare `reference_to` before its plain attributes. A
/// command that declares an argument first and a cross-reference second put the
/// two runtimes' IR out of order, and `market`'s `Let` is that command.
fn settle_references(cmd: &mut Command, owner: &str) {
    let mut acting = false;
    let kept: Vec<Attribute> = cmd
        .attributes
        .drain(..)
        .filter(|attribute| {
            // `acts_on_root` only admits a reference whose target IS the owner,
            // so the owner's name is the root's name.
            let root = acts_on_root(attribute, owner);
            acting |= root;
            !root
        })
        .collect();

    cmd.references = acting.then(|| owner.to_string());
    cmd.attributes = kept;
}

fn parse_role_arg(line: &str) -> Option<String> {
    let after = line.trim_start_matches("role").trim_start();
    if after.starts_with('"') {
        return extract_string(after);
    }
    let end = after
        .find(|c: char| c == ',' || c.is_whitespace())
        .unwrap_or(after.len());
    let token = after[..end].trim();
    if token.is_empty() {
        None
    } else {
        Some(token.to_string())
    }
}

fn parse_inline_command(line: &str, cmd: &mut Command) {
    if let Some(block) = extract_block(line) {
        for part in block.split(';') {
            let part = part.trim();
            if part.starts_with("role") {
                cmd.role = parse_role_arg(part);
            } else if part.starts_with("emits") {
                cmd.emits.extend(extract_string(part));
            } else if part.starts_with("attribute") {
                if let Some(attr) = parse_attribute(part) {
                    cmd.attributes.push(attr);
                }
            } else if part.starts_with("reference_to") {
                if let Some(target) = extract_word_after(part, "reference_to") {
                    let snake = crate::naming::snake(&target);
                    cmd.attributes.push(reference_attribute(snake, &target, false));
                }
            }
        }
    }
}

pub fn parse_query(lines: &[&str]) -> (Query, usize) {
    let first = lines[0].trim();
    let name = extract_string(first).unwrap_or_else(|| {
        first
            .split_whitespace()
            .nth(1)
            .unwrap_or("")
            .trim_matches('"')
            .to_string()
    });

    let mut q = Query {
        name,
        description: None,
        attributes: vec![],
        wheres: vec![],
        order_by: None,
        limit: None,
        offset: None,
        cursor: None,
        consistency: None,
        freshness: None,
        authorization: None,
        null_semantics: None,
        inspection: None,
        index_hints: vec![],
    };

    if let Some(open) = first.rfind('|') {
        if let Some(prev) = first[..open].rfind('|') {
            let inside = &first[prev + 1..open];
            for part in inside.split(',') {
                let nm = part.trim().trim_start_matches(':').to_string();
                if !nm.is_empty() {
                    q.attributes.push(Attribute {
                        name: nm,
                        r#type: "String".to_string(),
                        default: None,
                        list: false,
                        optional: false,
                        enum_values: vec![],
                        pattern: None,
                        admits: None,
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
            if depth == 0 {
                break;
            }
            i += 1;
            continue;
        }
        if depth == 1 {
            if line.starts_with("description") {
                q.description = extract_string(line);
            } else if line.starts_with("attribute") {
                if let Some(attr) = parse_attribute(line) {
                    q.attributes.push(attr);
                }
            } else if line.starts_with("where") {
                let param_names: Vec<String> =
                    q.attributes.iter().map(|a| a.name.clone()).collect();
                for w in parse_where_line(line, &param_names) {
                    q.wheres.push(w);
                }
            } else if line.starts_with("order_by") {
                if let Some(ob) = parse_order_by_line(line) {
                    q.order_by = Some(ob);
                }
            } else if line.starts_with("limit") {
                if let Some(ls) = parse_limit_line(line) {
                    q.limit = Some(ls);
                }
            } else if apply_option_line(
                line,
                &mut q.offset,
                &mut q.cursor,
                &mut q.consistency,
                &mut q.freshness,
                &mut q.authorization,
                &mut q.null_semantics,
                &mut q.inspection,
                &mut q.index_hints,
            ) {
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

// THE EIGHT SPECIFICATION OPTIONS, shared verbatim between `Query` and
// `ReadModel` — the same body Ruby's `QuerySpecification::Common::DSL` mixes
// into both. One function tries every keyword against a line and reports
// whether it matched, so the two callers (`parse_query`, `parse_read_model`)
// stay a single `else if` each rather than two copies of eight branches.
#[allow(clippy::too_many_arguments)]
fn apply_option_line(
    line: &str,
    offset: &mut Option<OffsetSpec>,
    cursor: &mut Option<CursorSpec>,
    consistency: &mut Option<ConsistencySpec>,
    freshness: &mut Option<FreshnessSpec>,
    authorization: &mut Option<AuthorizationSpec>,
    null_semantics: &mut Option<NullSemanticsSpec>,
    inspection: &mut Option<InspectionSpec>,
    index_hints: &mut Vec<IndexHint>,
) -> bool {
    if line.starts_with("offset") {
        *offset = parse_offset_line(line);
    } else if line.starts_with("cursor") {
        *cursor = parse_cursor_line(line);
    } else if line.starts_with("consistency") {
        *consistency = parse_consistency_line(line);
    } else if line.starts_with("freshness") {
        *freshness = parse_freshness_line(line);
    } else if line.starts_with("authorize") {
        *authorization = parse_authorize_line(line);
    } else if line.starts_with("nulls") {
        *null_semantics = parse_nulls_line(line);
    } else if line.starts_with("inspect_query") {
        *inspection = parse_inspect_query_line(line);
    } else if line.starts_with("use_index") {
        if let Some(hint) = parse_use_index_line(line) {
            index_hints.push(hint);
        }
    } else {
        return false;
    }
    true
}

// STRIPS A LEADING COLON. Every one of these eight fields is DECLARED as a
// symbol (`:snapshot`, `:operator_access`, ...), and Ruby's own `to_h` methods
// disagree about whether the colon survives: `OffsetSpec`/`CursorSpec` render
// through `QuerySpecification.render_value`, which keeps it ; every other
// struct (`ConsistencySpec`, `FreshnessSpec`, `AuthorizationSpec`,
// `NullSemantics`, `InspectionSpec`, `IndexHint`) calls plain `.to_s`, which
// does not. So `parse_cursor_line` keeps the colon `extract_word_after`
// already captures, and every other parser here strips it.
fn strip_symbol_colon(value: String) -> String {
    value.trim_start_matches(':').to_string()
}

pub fn parse_offset_line(line: &str) -> Option<OffsetSpec> {
    extract_word_after(line, "offset").map(|value| OffsetSpec { value })
}

pub fn parse_cursor_line(line: &str) -> Option<CursorSpec> {
    extract_word_after(line, "cursor").map(|value| CursorSpec { value })
}

pub fn parse_consistency_line(line: &str) -> Option<ConsistencySpec> {
    let mode = strip_symbol_colon(extract_word_after(line, "consistency")?);
    let timeout = extract_word_after(line, "timeout:");
    Some(ConsistencySpec { mode, timeout })
}

pub fn parse_freshness_line(line: &str) -> Option<FreshnessSpec> {
    let mode = strip_symbol_colon(extract_word_after(line, "freshness")?);
    let max_age = extract_word_after(line, "max_age:");
    Some(FreshnessSpec { mode, max_age })
}

pub fn parse_authorize_line(line: &str) -> Option<AuthorizationSpec> {
    let policy = strip_symbol_colon(extract_word_after(line, "authorize")?);
    let tenant = extract_word_after(line, "tenant:").map(strip_symbol_colon);
    Some(AuthorizationSpec { policy, tenant })
}

pub fn parse_nulls_line(line: &str) -> Option<NullSemanticsSpec> {
    extract_word_after(line, "nulls")
        .map(strip_symbol_colon)
        .map(|mode| NullSemanticsSpec { mode })
}

pub fn parse_inspect_query_line(line: &str) -> Option<InspectionSpec> {
    extract_word_after(line, "inspect_query")
        .map(strip_symbol_colon)
        .map(|mode| InspectionSpec { mode })
}

pub fn parse_use_index_line(line: &str) -> Option<IndexHint> {
    extract_word_after(line, "use_index")
        .map(strip_symbol_colon)
        .map(|name| IndexHint { name })
}

pub fn parse_where_line(line: &str, param_names: &[String]) -> Vec<WhereClause> {
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
        if part.is_empty() {
            continue;
        }
        if let Some(colon) = part.find(':') {
            let field = part[..colon].trim().to_string();
            let raw = part[colon + 1..].trim();
            if field.is_empty() {
                continue;
            }
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

fn extract_where_value(raw: &str, param_names: &[String]) -> String {
    let raw = raw.trim();
    if raw.starts_with('"') {
        extract_string(raw).unwrap_or_default()
    } else if raw.starts_with('\'') {
        let inner = raw.trim_start_matches('\'');
        let close = inner.rfind('\'').unwrap_or(inner.len());
        inner[..close].to_string()
    } else if raw.starts_with('[') {
        let inner = raw.trim_start_matches('[');
        let close = inner.rfind(']').unwrap_or(inner.len());
        split_top_level_commas(&inner[..close])
            .iter()
            .map(|it| {
                it.trim()
                    .trim_matches('"')
                    .trim_matches('\'')
                    .trim()
                    .to_string()
            })
            .filter(|s| !s.is_empty())
            .collect::<Vec<_>>()
            .join(",")
    } else if raw.starts_with(':') {
        raw.split(|c: char| c == ',' || c.is_whitespace())
            .next()
            .unwrap_or("")
            .to_string()
    } else {
        let token = raw
            .split(|c: char| c == ',' || c.is_whitespace())
            .next()
            .unwrap_or("")
            .to_string();
        if param_names.iter().any(|p| p == &token) {
            format!(":{}", token)
        } else {
            token
        }
    }
}

fn parse_comparator_hash(raw: &str) -> Option<(WhereOp, &str)> {
    let raw = raw.trim_start_matches('{');
    let close = raw.rfind('}')?;
    let inner = raw[..close].trim();
    let colon = inner.find(':')?;
    let op_key = inner[..colon].trim().trim_start_matches(':');
    let value_part = inner[colon + 1..].trim();
    let op = match op_key {
        "lt" => WhereOp::Lt,
        "lte" => WhereOp::Lte,
        "gt" => WhereOp::Gt,
        "gte" => WhereOp::Gte,
        "ne" => WhereOp::Ne,
        "eq" => WhereOp::Eq,
        "in" => WhereOp::In,
        "contains" => WhereOp::Contains,
        _ => return None,
    };
    Some((op, value_part))
}

pub fn parse_order_by_line(line: &str) -> Option<OrderBy> {
    let body = line.trim_start_matches("order_by").trim();
    let body = body.trim_start_matches('(').trim_end_matches(')');
    let parts: Vec<&str> = body.split(',').map(|s| s.trim()).collect();
    let field_part = parts.first()?;
    let field = field_part.trim_start_matches(':').to_string();
    if field.is_empty() {
        return None;
    }
    let direction = match parts.get(1).map(|s| s.trim_start_matches(':')) {
        Some("desc") | Some("Desc") | Some("DESC") => Direction::Desc,
        _ => Direction::Asc,
    };
    Some(OrderBy { field, direction })
}

pub fn parse_limit_line(line: &str) -> Option<LimitSpec> {
    let body = line.trim_start_matches("limit").trim();
    let body = body.trim_start_matches('(').trim_end_matches(')');
    let token = body
        .split(|c: char| c == ',' || c.is_whitespace())
        .next()?
        .trim();
    if token.is_empty() {
        return None;
    }
    Some(LimitSpec {
        value: token.to_string(),
    })
}

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

fn inline_do_pos(line: &str) -> Option<usize> {
    let after_message = match line.find('"') {
        Some(open) => line[open + 1..]
            .find('"')
            .map(|close| open + 1 + close + 1)
            .unwrap_or(0),
        None => 0,
    };
    line[after_message..]
        .find(" do ")
        .map(|at| after_message + at)
}

pub fn parse_value_object(lines: &[&str]) -> (ValueObject, usize) {
    let first = lines[0].trim();
    let name = extract_string(first).unwrap_or_default();
    let mut vo = ValueObject {
        name,
        attributes: vec![],
        invariants: vec![],
        members: vec![],
        closed_set: false,
    };

    let mut i = 1;
    let mut depth = 1;
    while i < lines.len() && depth > 0 {
        let line = lines[i].trim();
        if line == "end" {
            depth -= 1;
            if depth == 0 {
                break;
            }
        } else if depth == 1 && (line == "one_of do" || line.starts_with("one_of do")) {
            vo.closed_set = true;
            let mut j = i + 1;
            let mut d = 1;
            while j < lines.len() && d > 0 {
                let l = lines[j].trim();
                if l == "end" {
                    d -= 1;
                    if d == 0 {
                        break;
                    }
                } else if ends_with_do_block(l) {
                    d += 1;
                } else if l.starts_with("member ") || l.starts_with("member(") {
                    let body = l
                        .trim_start_matches("member")
                        .trim_start_matches('(')
                        .trim_end_matches(')');
                    let mut fields: Vec<(String, String)> = Vec::new();
                    for pair in split_member_pairs(body) {
                        if let Some(colon) = pair.find(':') {
                            let key = pair[..colon].trim().trim_matches(':').to_string();
                            let raw_val = pair[colon + 1..].trim();
                            let bare = raw_val.trim_matches(',').trim();
                            let val = extract_string(raw_val).unwrap_or_else(|| bare.to_string());
                            let declared = bare.starts_with('"') || !val.is_empty();
                            if !key.is_empty() && declared {
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
            let inv_name = extract_string(line).unwrap_or_default();
            if let (Some(open), Some(stripped)) = (line.find('{'), line.strip_suffix('}')) {
                let expr = stripped[open + 1..].trim();
                if !inv_name.is_empty() && !expr.is_empty() {
                    vo.invariants.push(Invariant {
                        description: inv_name,
                        canonical: expr.to_string(),
                    });
                }
            }
        } else if depth == 1
            && line.starts_with("invariant")
            && line.contains(" do ")
            && line.ends_with("end")
        {
            let inv_name = extract_string(line).unwrap_or_default();
            if let (Some(do_pos), Some(stripped)) = (inline_do_pos(line), line.strip_suffix("end"))
            {
                let expr = stripped[do_pos + " do ".len()..].trim();
                if !inv_name.is_empty() && !expr.is_empty() {
                    vo.invariants.push(Invariant {
                        description: inv_name,
                        canonical: expr.to_string(),
                    });
                }
            }
        } else if depth == 1 && line.starts_with("invariant") && ends_with_do_block(line) {
            let inv_name = extract_string(line).unwrap_or_default();
            let mut body: Vec<&str> = Vec::new();
            let mut j = i + 1;
            let mut d = 1;
            while j < lines.len() && d > 0 {
                let l = lines[j].trim();
                if l == "end" {
                    d -= 1;
                    if d == 0 {
                        break;
                    }
                } else if ends_with_do_block(l) {
                    d += 1;
                }
                if d >= 1 && !l.is_empty() {
                    body.push(l);
                }
                j += 1;
            }
            if !inv_name.is_empty() && !body.is_empty() {
                vo.invariants.push(Invariant {
                    description: inv_name,
                    canonical: join_predicate_lines(&body),
                });
            }
            i = j + 1;
            continue;
        } else if ends_with_do_block(line) {
            depth += 1;
        }
        if depth == 1 {
            if line.starts_with("attribute") {
                if let Some(attr) = parse_attribute(line) {
                    vo.attributes.push(attr);
                }
            }
        }
        i += 1;
    }
    (vo, i + 1)
}

pub fn parse_entity(lines: &[&str]) -> (Entity, usize) {
    let first = lines[0].trim();
    let name = extract_string(first).unwrap_or_default();
    let owner = name.clone();
    let mut ent = Entity {
        name,
        description: None,
        attributes: vec![],
        commands: vec![],
        queries: vec![],
        lifecycle: None,
        identified_by: vec![],
    };

    let mut i = 1;
    let mut depth = 1;
    while i < lines.len() && depth > 0 {
        let line = lines[i].trim();

        if line == "end" {
            depth -= 1;
            if depth == 0 {
                break;
            }
            i += 1;
            continue;
        }

        if depth == 1 {
            if line.starts_with("command") {
                let (cmd, consumed) = parse_command(&lines[i..], &owner);
                ent.commands.push(cmd);
                i += consumed;
                continue;
            } else if line.starts_with("query") {
                if ends_with_do_block(line) {
                    let (q, consumed) = parse_query(&lines[i..]);
                    ent.queries.push(q);
                    i += consumed;
                    continue;
                }
                let q_name = extract_string(line).unwrap_or_else(|| {
                    line.split_whitespace()
                        .nth(1)
                        .unwrap_or("")
                        .trim_matches('"')
                        .to_string()
                });
                let q_desc = extract_second_string(line);
                ent.queries.push(Query {
                    name: q_name,
                    description: q_desc,
                    attributes: vec![],
                    wheres: vec![],
                    order_by: None,
                    limit: None,
                    offset: None,
                    cursor: None,
                    consistency: None,
                    freshness: None,
                    authorization: None,
                    null_semantics: None,
                    inspection: None,
                    index_hints: vec![],
                });
            } else if line.starts_with("lifecycle") {
                let (lc, consumed) = parse_lifecycle(&lines[i..]);
                ent.lifecycle = Some(lc);
                i += consumed;
                continue;
            } else if line.starts_with("identified_by") {
                let (paths, consumed) = extract_identity_paths(&lines[i..]);
                ent.identified_by = paths;
                i += consumed;
                continue;
            } else if line.starts_with("description") {
                ent.description = extract_string(line);
            } else if line.starts_with("attribute") {
                if let Some(attr) = parse_attribute(line) {
                    ent.attributes.push(attr);
                }
                if ends_with_do_block(line) {
                    let (lc, consumed) = parse_lifecycle(&lines[i..]);
                    if !lc.transitions.is_empty() {
                        ent.lifecycle = Some(lc);
                    }
                    i += consumed;
                    continue;
                }
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
        if line == "end" {
            break;
        }
        if line.starts_with("on") {
            on_event = extract_string(line).unwrap_or_default();
        }
        if line.starts_with("trigger") {
            trigger = extract_string(line).unwrap_or_default();
        }
        if line.starts_with("across") {
            target_domain = extract_string(line);
        }
        i += 1;
    }
    (
        Policy {
            name,
            on_event,
            trigger_command: trigger,
            target_domain,
        },
        i + 1,
    )
}

pub fn parse_lifecycle(lines: &[&str]) -> (Lifecycle, usize) {
    let first = lines[0].trim();
    let field = extract_symbol(first).unwrap_or_default();
    let default = if first.contains("default:") {
        let after = extract_after(first, "default:").unwrap_or_default();
        extract_state_token(&after).unwrap_or_default()
    } else {
        String::new()
    };

    let mut transitions = vec![];
    let mut i = 1;
    while i < lines.len() {
        let line = lines[i].trim();
        if line == "end" {
            break;
        }
        if line.starts_with("transition") {
            if let Some(cmd) = extract_string(line) {
                let to_state = line
                    .find("=>")
                    .and_then(|arrow| extract_state_token(&line[arrow + 2..]));
                let from_states: Vec<Option<String>> = if line.contains("from:") {
                    let after = extract_after(line, "from:").unwrap_or_default();
                    let trimmed = after.trim_start();
                    if trimmed.starts_with('[') {
                        let close = trimmed.find(']').unwrap_or(trimmed.len());
                        let inner = &trimmed[1..close];
                        let found: Vec<Option<String>> = inner
                            .split(',')
                            .filter_map(|part| extract_state_token(part).map(Some))
                            .collect();
                        if found.is_empty() {
                            vec![None]
                        } else {
                            found
                        }
                    } else {
                        vec![extract_state_token(&after)]
                    }
                } else {
                    vec![None]
                };
                if let Some(to) = to_state {
                    for from_state in from_states {
                        transitions.push(Transition {
                            command: cmd.clone(),
                            to_state: to.clone(),
                            from_state,
                        });
                    }
                }
            }
        }
        i += 1;
    }
    (
        Lifecycle {
            field,
            default,
            transitions,
        },
        i + 1,
    )
}

/// Join a predicate's lines the way Ruby's extractor reads them.
///
/// Each line of a multi-line `given` / `invariant` body is normally a separate
/// clause, so the default join is ` && `. But a line that ENDS with a boolean
/// operator — or the next one that STARTS with it — is a CONTINUATION of the
/// same expression, and inserting another operator produced:
///
///   Ruby   cents >= 0 && cents < 1000000
///   Rust   cents >= 0 && && cents < 1000000
///
/// Ruby collapses the continuation, so the two runtimes read a DIFFERENT
/// canonical form from the same source and IR parity split on any multi-line
/// predicate. The corpus worked around it by keeping predicates on one line ;
/// this removes the reason for the workaround.
pub(crate) fn join_predicate_lines(body: &[&str]) -> String {
    let mut out = String::new();
    for line in body {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        if out.is_empty() {
            out.push_str(line);
            continue;
        }
        if continues(&out) || continued_by(line) {
            out.push(' ');
        } else {
            out.push_str(" && ");
        }
        out.push_str(line);
    }
    out
}

/// The text so far ends mid-expression, so the next line finishes it.
fn continues(text: &str) -> bool {
    let t = text.trim_end();
    t.ends_with("&&") || t.ends_with("||")
}

/// The next line opens with the operator that joins it to what came before.
fn continued_by(line: &str) -> bool {
    let t = line.trim_start();
    t.starts_with("&&") || t.starts_with("||")
}

#[cfg(test)]
mod predicate_join_tests {
    use super::join_predicate_lines;

    /// THE SPLIT. A line ending in `&&` is a CONTINUATION, not a clause — the
    /// old `body.join(" && ")` read `value > 0 && && value <= 3` where Ruby
    /// reads one expression, so the two parsers disagreed about the same file.
    #[test]
    fn a_trailing_operator_is_a_continuation_not_a_clause() {
        assert_eq!(
            join_predicate_lines(&["value > 0 &&", "value <= 3"]),
            "value > 0 && value <= 3"
        );
        assert_eq!(
            join_predicate_lines(&["a.positive? ||", "b.positive?"]),
            "a.positive? || b.positive?"
        );
    }

    /// The operator may lead the next line instead of trailing the last one.
    #[test]
    fn a_leading_operator_is_a_continuation_too() {
        assert_eq!(
            join_predicate_lines(&["value > 0", "&& value <= 3"]),
            "value > 0 && value <= 3"
        );
    }

    /// AND THE REASON THE JOIN EXISTS: two separate statements ARE two clauses,
    /// and still get the operator inserted between them.
    #[test]
    fn separate_statements_are_still_joined_with_and() {
        assert_eq!(
            join_predicate_lines(&["cents >= 0", "currency.size == 3"]),
            "cents >= 0 && currency.size == 3"
        );
    }

    #[test]
    fn one_line_and_no_lines_are_unchanged() {
        assert_eq!(join_predicate_lines(&["value > 0"]), "value > 0");
        assert_eq!(join_predicate_lines(&[]), "");
        assert_eq!(join_predicate_lines(&["", "  "]), "");
    }
}

pub fn parse_attribute(line: &str) -> Option<Attribute> {
    let line = strip_trailing_comment(line);
    let parts: Vec<&str> = line.splitn(3, ',').collect();
    let first = parts.first()?.trim();

    let (name, attr_type) = if let Some(sym) = extract_symbol(first) {
        (sym, None)
    } else {
        let vo_name = bare_vo_type(first)?;
        let alias = parts
            .get(1)
            .and_then(|p| p.find("as:").map(|pos| &p[pos + "as:".len()..]))
            .and_then(extract_symbol)
            .unwrap_or_else(|| crate::naming::snake(&vo_name));
        (alias, Some(vo_name))
    };

    let raw = parts.get(1).map(|s| s.trim()).unwrap_or("");
    let list = line.contains("list_of(");
    let attr_type = if let Some(t) = attr_type {
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

    let optional = line.contains("optional:")
        && extract_after(line, "optional:")
            .map(|a| a.trim_start().starts_with("true"))
            .unwrap_or(false);
    let default = if line.contains("default:") {
        Some(extract_after(line, "default:")?.trim().to_string())
    } else {
        None
    };
    let (attr_type, enum_values) = if let Some(start) = line.find("one_of(") {
        let inner = &line[start + "one_of(".len()..];
        let close = inner.find(')').unwrap_or(inner.len());
        let vals: Vec<String> = inner[..close]
            .split(',')
            .filter_map(extract_string)
            .collect();
        ("String".to_string(), vals)
    } else {
        (attr_type, vec![])
    };
    let pattern = parse_pattern_kwarg(line);
    let admits = parse_quoted_kwarg(line, "admits:");
    Some(Attribute {
        name,
        r#type: attr_type,
        default,
        list,
        optional,
        enum_values,
        pattern,
        admits,
    })
}

/// A kwarg whose value is a QUOTED STRING — `admits: "Vocabulary::MutationOp"`.
///
/// Split out of `parse_pattern_kwarg`, which read exactly this shape and then
/// went on to validate a regex. `admits` is the second reader of the shape and
/// wants none of the validating, so the reading is the part they share.
pub(crate) fn parse_quoted_kwarg(line: &str, kwarg: &str) -> Option<String> {
    let after = line.split(kwarg).nth(1)?.trim_start();
    let quote = after.chars().next().filter(|c| *c == '\'' || *c == '"')?;
    Some(
        after[quote.len_utf8()..]
            .chars()
            .take_while(|c| *c != quote)
            .collect(),
    )
}

fn parse_pattern_kwarg(line: &str) -> Option<String> {
    let body = parse_quoted_kwarg(line, "pattern:")?;
    match crate::pattern_subset::validate_pattern_subset(&body) {
        Ok(()) => Some(body),
        Err(rejection) => {
            eprintln!(
                "[bluebook] pattern REFUSED ({}): {}\n  in: {}\n  — {}",
                rejection.construct,
                body,
                line.trim(),
                rejection.reason,
            );
            None
        }
    }
}

fn bare_vo_type(first: &str) -> Option<String> {
    let after_kw = first.strip_prefix("attribute")?.trim_start();
    let token: String = after_kw
        .chars()
        .take_while(|c| c.is_alphanumeric() || *c == '_')
        .collect();
    if token.is_empty() {
        return None;
    }
    let mut chars = token.chars();
    let head = chars.next()?;
    if !head.is_uppercase() {
        return None;
    }
    Some(token)
}

fn is_kwarg(s: &str) -> bool {
    let Some(colon_pos) = s.find(':') else {
        return false;
    };
    let before = &s[..colon_pos];
    !before.is_empty()
        && before
            .chars()
            .next()
            .is_some_and(|c| c.is_ascii_lowercase())
        && before.chars().all(|c| c.is_alphanumeric() || c == '_')
}

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
    let (op, value) = if line.contains("append:") {
        (MutationOp::Append, extract_after(line, "append:")?)
    } else if line.contains("increment:") {
        (MutationOp::Increment, extract_after(line, "increment:")?)
    } else if line.contains("decrement:") {
        (MutationOp::Decrement, extract_after(line, "decrement:")?)
    } else if line.contains("to:") {
        (MutationOp::Set, extract_after(line, "to:")?)
    } else {
        let sym_start = line.find(':')? + 1;
        let after_field = &line[sym_start + field.len()..];
        let comma = after_field.find(',')?;
        let raw = after_field[comma + 1..].trim();
        let rb = raw.as_bytes();
        if rb
            .first()
            .is_some_and(|b| b.is_ascii_lowercase() || *b == b'_')
        {
            let end = rb
                .iter()
                .take_while(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || **b == b'_')
                .count();
            if raw[end..].starts_with(':') {
                return Some(Mutation {
                    target: field,
                    op: MutationOp::Set,
                    source: String::new(),
                });
            }
        }
        let value = if let Some(rest) = raw.strip_prefix('"') {
            let end = rest.find('"')?;
            rest[..end].to_string()
        } else {
            raw.split(|c: char| c == ',' || c.is_whitespace())
                .next()
                .unwrap_or("")
                .to_string()
        };
        if value.is_empty() {
            return None;
        }
        (MutationOp::Set, value)
    };
    Some(Mutation {
        target: field,
        op,
        source: value,
    })
}

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
            if depth == 0 {
                break;
            }
            i += 1;
            continue;
        }

        if depth == 1 {
            if line.starts_with("correlates_by") {
                if let Some(sym) = extract_symbol(line) {
                    pm.correlates_by = sym;
                }
            } else if line.starts_with("starts_on") {
                if let Some(s) = extract_string(line) {
                    pm.starts_on = s;
                }
            } else if line.starts_with("ends_on") {
                if let Some(s) = extract_string(line) {
                    pm.ends_on = Some(s);
                }
            } else if line.starts_with("state ") || line.starts_with("state\t") {
                if let Some(s) = extract_string(line) {
                    pm.states.push(s);
                }
            } else if line.starts_with("on ") || line.starts_with("on\t") {
                let mut handler = parse_pm_handler(line);
                if ends_with_do_block(line) {
                    let on_indent = lines[i].len() - lines[i].trim_start().len();
                    while i + 1 < lines.len() {
                        i += 1;
                        let raw = lines[i];
                        let trimmed = raw.trim();
                        let indent = raw.len() - raw.trim_start().len();
                        if trimmed == "end" && indent == on_indent {
                            break;
                        }
                        if !is_dispatch_start(trimmed) {
                            continue;
                        }
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
                            }
                        }
                    }
                }
                if let Some(h) = handler {
                    pm.handlers.push(h);
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

fn parse_pm_handler(line: &str) -> Option<ProcessManagerHandler> {
    // `on "EventName", transition: {…}` — or `on :refused, transition: {…}`.
    //
    // A SYMBOL trigger is not an event name: `:refused` is the procedure noticing
    // that a leg it dispatched was declined, and no aggregate announces it. It
    // has to be read before extract_string, which takes the first QUOTED string
    // on the line and so reaches straight past the symbol to pick up the
    // transition's from-state. That read banking's compensating leg as
    // `event_type: "awaiting_credit"` and split the two parsers.
    let head = line.trim().strip_prefix("on")?.trim_start();
    let event_type = if let Some(symbol) = head.strip_prefix(':') {
        symbol
            .split(|c: char| c == ',' || c.is_whitespace())
            .next()?
            .to_string()
    } else {
        extract_string(line)?
    };
    let trans_pos = line.find("transition:")?;
    let after = &line[trans_pos + "transition:".len()..];
    let open = after.find('{')?;
    let close = after[open..].find('}')? + open;
    let body = after[open + 1..close].trim();
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
        let to = rhs
            .split(|c: char| c == ',' || c.is_whitespace())
            .next()
            .unwrap_or("")
            .to_string();
        (from, to)
    };
    if from.is_empty() || to.is_empty() {
        return None;
    }
    Some(ProcessManagerHandler {
        event_type,
        from_state: from,
        to_state: to,
        dispatches: vec![],
    })
}

fn is_dispatch_start(trimmed: &str) -> bool {
    trimmed.starts_with("dispatch ")
        || trimmed.starts_with("dispatch\t")
        || trimmed.starts_with("dispatch\"")
}

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

fn parse_dispatch_statement(line: &str) -> Option<DispatchSpec> {
    let trimmed = line.trim();
    if !is_dispatch_start(trimmed) {
        return None;
    }
    let command_name = extract_string(trimmed)?;

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
            let close = match_close_brace(&after[open..])? + open;
            let body = after[open + 1..close].trim();
            parse_with_hash(body)
        }
    };

    Some(DispatchSpec {
        command_name,
        with_spec,
    })
}

fn match_close_brace(s: &str) -> Option<usize> {
    let mut depth = 0i32;
    for (i, c) in s.char_indices() {
        match c {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if depth == 0 {
                    return Some(i);
                }
            }
            _ => (),
        }
    }
    None
}

fn parse_with_hash(body: &str) -> Vec<(String, String)> {
    let mut out: Vec<(String, String)> = Vec::new();
    for raw_entry in split_top_level_commas(body) {
        let entry = raw_entry.trim().trim_end_matches(',').trim();
        if entry.is_empty() {
            continue;
        }
        let colon = match entry.find(':') {
            Some(p) => p,
            None => continue,
        };
        let key_raw = entry[..colon].trim();
        let val_raw = entry[colon + 1..].trim();
        let key = key_raw
            .trim_matches(|c| c == '"' || c == '\'' || c == ':')
            .to_string();
        if key.is_empty() {
            continue;
        }
        if let Some(value) = parse_binding_value(val_raw) {
            out.push((key, value));
        }
    }
    out
}

/// `Dispatch.Bind`'s `value` — the same text `IR.render_value` put on the
/// wire, and nothing richer. A leading colon (`:source`) means an argument
/// the event or process manager memory carries ; anything else, including a
/// nested object literal, is read as-is and interpreted at actual dispatch
/// time (`dispatcher.rs::deliver_saga_dispatch`), not here.
fn parse_binding_value(raw: &str) -> Option<String> {
    let s = raw.trim();
    if s.starts_with('"') || s.starts_with('\'') {
        extract_string(s)
    } else {
        let token = s.trim_end_matches(',').trim().to_string();
        if token.is_empty() {
            None
        } else {
            Some(token)
        }
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

    /// A QUOTED STRING has its quotes stripped ; a BARE SYMBOL keeps its
    /// colon, because the colon is what tells an argument the event or
    /// process manager memory carries from a string that just happens to
    /// share its shape — `dispatcher.rs::deliver_saga_dispatch` reads that
    /// colon at actual dispatch time. Neither runtime has ever needed a
    /// third case : `from_event(...)`/`from_pm(...)`/`from_iter(...)` sentinel
    /// syntax used to be read into a distinct `ValueSpec` here, but no Ruby
    /// method by any of those three names exists in this project or in Hecks,
    /// and `bin/ir_rust`'s own generator only ever emitted a literal. Deleted ;
    /// see the comment on `DispatchSpec` in `ir.rs`.
    #[test]
    fn parses_a_quoted_literal_and_a_bare_symbol() {
        let line = r#"dispatch "Body.Tick", with: { name: "body", tick: :tick }"#;
        let s = parse_dispatch_statement(line).unwrap();
        assert_eq!(s.command_name, "Body.Tick");
        assert_eq!(s.with_spec.len(), 2);
        assert_eq!(s.with_spec[0], ("name".to_string(), "body".to_string()));
        assert_eq!(s.with_spec[1], ("tick".to_string(), ":tick".to_string()));
    }

    #[test]
    fn tolerates_variable_whitespace_around_with() {
        let line = r#"dispatch "X.Y",          with: { tick: :tick }"#;
        let s = parse_dispatch_statement(line).unwrap();
        assert_eq!(s.with_spec.len(), 1);
        assert_eq!(s.with_spec[0].0, "tick");
    }

    #[test]
    fn preserves_with_declaration_order() {
        let line = r#"dispatch "X.Y", with: { a: 1, b: 2, c: 3 }"#;
        let s = parse_dispatch_statement(line).unwrap();
        assert_eq!(
            s.with_spec
                .iter()
                .map(|(k, _)| k.as_str())
                .collect::<Vec<_>>(),
            vec!["a", "b", "c"]
        );
    }

}
