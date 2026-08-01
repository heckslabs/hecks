use crate::ir::*;
use crate::parser_helpers::*;

pub fn parse_read_model(lines: &[&str]) -> (ReadModel, usize) {
    let first = lines[0].trim();
    let mut model = ReadModel { name: extract_string(first).unwrap_or_default(), description: None, reference_name: String::new(), reference_target: String::new(), aggregate_heads: vec![] };
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
            } else if is_shorthand_line(line) {
                match parse_shorthand(line) {
                    ShorthandResult::Attribute(a) => cmd.attributes.push(a),
                    ShorthandResult::Reference(r) => cmd.attributes.push(r),
                    ShorthandResult::None => {}
                }
            } else if line.starts_with("role") {
                cmd.role = parse_role_arg(line);
            } else if line.starts_with("goal") || line.starts_with("description") {
                cmd.goal = extract_string(line);
            } else if line.starts_with("emits") {
                cmd.emits.extend(extract_string(line));
            } else if line.starts_with("reference_to") {
                if let Some(target) = extract_word_after(line, "reference_to") {
                    let name = if let Some(pos) = line.find(", as:") {
                        let after = &line[pos + ", as:".len()..];
                        extract_symbol(after).unwrap_or_else(|| format!("{}_id", crate::naming::snake(&target)))
                    } else if let Some(pos) = line.find(", role:") {
                        let after = &line[pos + ", role:".len()..];
                        extract_symbol(after).unwrap_or_else(|| format!("{}_id", crate::naming::snake(&target)))
                    } else {
                        format!("{}_id", crate::naming::snake(&target))
                    };
                    cmd.attributes.push(reference_attribute(name, &target));
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
                    cmd.attributes.push(reference_attribute(snake, &target));
                }
            } else if is_shorthand_line(part) {
                match parse_shorthand(part) {
                    ShorthandResult::Attribute(a) => cmd.attributes.push(a),
                    ShorthandResult::Reference(r) => cmd.attributes.push(r),
                    ShorthandResult::None => {}
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
        } else if depth == 1 && (line.starts_with("rule ") || line.starts_with("rule\t")) {
            let consumed = consume_rule_block(&lines[i..]);
            i += consumed;
            continue;
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
            } else if is_shorthand_line(line) && !line.starts_with("reference_to(") {
                if let Some(attr) = parse_shorthand_attribute(line) {
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
            if line.starts_with("command") || is_shorthand_command(line) {
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
            } else if is_shorthand_line(line) && !line.starts_with("reference_to(") {
                if let Some(attr) = parse_shorthand_attribute(line) {
                    ent.attributes.push(attr);
                }
            } else if line.starts_with("rule ") || line.starts_with("rule\t") {
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
                        if !is_dispatch_start(trimmed) && !is_set_start(trimmed) {
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

fn is_set_start(trimmed: &str) -> bool {
    trimmed.starts_with("set ") || trimmed.starts_with("set\t")
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

fn parse_with_hash(body: &str) -> Vec<(String, ValueSpec)> {
    let mut out: Vec<(String, ValueSpec)> = Vec::new();
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
        if let Some(spec) = parse_value_spec(val_raw) {
            out.push((key, spec));
        }
    }
    out
}

fn parse_value_spec(raw: &str) -> Option<ValueSpec> {
    let s = raw.trim();
    if s.starts_with("from_event") {
        let (name, default) = parse_sentinel_args(s, "from_event")?;
        Some(ValueSpec::FromEvent { name, default })
    } else if s.starts_with("from_pm") {
        let (name, default) = parse_sentinel_args(s, "from_pm")?;
        Some(ValueSpec::FromPm { name, default })
    } else if s.starts_with("from_iter") {
        let (name, _default) = parse_sentinel_args(s, "from_iter")?;
        Some(ValueSpec::FromIter { field: name })
    } else if s.starts_with('"') || s.starts_with('\'') {
        let value = extract_string(s).unwrap_or_default();
        Some(ValueSpec::Literal { value })
    } else {
        let token = s.trim_end_matches(',').trim().to_string();
        if token.is_empty() {
            return None;
        }
        Some(ValueSpec::Literal { value: token })
    }
}

fn parse_sentinel_args(s: &str, fname: &str) -> Option<(String, Option<String>)> {
    let after = &s[fname.len()..];
    let open = after.find('(')?;
    let close = after[open..].rfind(')')? + open;
    let inner = after[open + 1..close].trim();
    if inner.is_empty() {
        return None;
    }

    let parts = split_top_level_commas(inner);
    let mut iter = parts.into_iter();
    let name_raw = iter.next()?.trim().to_string();
    let name = name_raw
        .trim_start_matches(':')
        .trim_matches(|c: char| c == '"' || c == '\'')
        .to_string();
    if name.is_empty() {
        return None;
    }

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

pub fn consume_rule_block(lines: &[&str]) -> usize {
    let first = lines[0].trim();
    let rule_name = extract_string(first).unwrap_or_default();

    if !ends_with_do_block(first) {
        return 1;
    }

    let mut depth: i32 = 1;
    let mut i = 1;
    while i < lines.len() && depth > 0 {
        let line = lines[i].trim();

        if let Some(tail) = line.strip_prefix("requires") {
            let after = &tail.trim_start();
            if after.starts_with('{') {
                let (body, body_end_idx) = read_requires_brace_body(lines, i);
                check_requires_body(&rule_name, &body, i + 1, body_end_idx + 1);
                i = body_end_idx + 1;
                continue;
            }
        }

        depth += count_rule_openers(line);
        if line == "end" {
            depth -= 1;
            if depth == 0 {
                return i + 1;
            }
        }
        i += 1;
    }

    i
}

fn read_requires_brace_body(lines: &[&str], start: usize) -> (String, usize) {
    let first = lines[start];
    let open_idx = match first.find('{') {
        Some(i) => i,
        None => return (String::new(), start),
    };
    let after_open = &first[open_idx + 1..];

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

fn check_requires_body(rule_name: &str, body: &str, start_line: usize, end_line: usize) {
    let trimmed = body.trim();
    if trimmed.is_empty() {
        return;
    }

    let mut has_multi = false;
    let multi_keywords: &[&str] = &[
        "if ", "unless ", "case ", "begin", "while ", "until ", "else", "elsif", "when ", "for ",
    ];
    for raw in body.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        for kw in multi_keywords {
            let kw_trim = kw.trim_end();
            if line == kw_trim || line.starts_with(kw) {
                has_multi = true;
                break;
            }
        }
        if line == "end" {
            has_multi = true;
        }
        if has_multi {
            break;
        }
    }

    if !has_multi {
        let mut paren_depth: i32 = 0;
        for c in trimmed.chars() {
            match c {
                '(' | '[' | '{' => paren_depth += 1,
                ')' | ']' | '}' => paren_depth -= 1,
                ';' if paren_depth == 0 => {
                    has_multi = true;
                    break;
                }
                _ => {}
            }
        }
    }

    if !has_multi {
        return;
    }

    let hint = derive_requires_hint(trimmed).unwrap_or_else(|| {
        "Combine with `&&` / `||` or split into multiple `requires` blocks.".to_string()
    });

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

fn derive_requires_hint(body: &str) -> Option<String> {
    let mut iter = body
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with('#'));
    let first = iter.next()?;
    let cond = first.strip_prefix("if ")?;
    let then_expr = iter.next()?;
    let else_kw = iter.next()?;
    if else_kw != "else" {
        return None;
    }
    let else_expr = iter.next()?;
    let end_kw = iter.next()?;
    if end_kw != "end" {
        return None;
    }
    if iter.next().is_some() {
        return None;
    }
    Some(format!(
        "Try : ({} && {}) || (!({}) && {})",
        cond.trim(),
        then_expr.trim(),
        cond.trim(),
        else_expr.trim()
    ))
}

fn count_rule_openers(line: &str) -> i32 {
    let mut count: i32 = 0;
    let trimmed = line.trim();

    if ends_with_do_block(trimmed) {
        count += 1;
    }

    let openers: &[&str] = &[
        "if ", "unless ", "case ", "while ", "until ", "for ", "begin", "def ", "class ", "module ",
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
        assert!(
            matches!(s.with_spec[1].1, ValueSpec::FromEvent { ref name, default: None } if name == "tick")
        );
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
        assert_eq!(
            s.with_spec
                .iter()
                .map(|(k, _)| k.as_str())
                .collect::<Vec<_>>(),
            vec!["a", "b", "c"]
        );
    }

    #[test]
    fn is_set_start_distinguishes_set_directive() {
        assert!(is_set_start("set :carrying, \"body\""));
        assert!(is_set_start("set\t:tick, from_event(:tick)"));
        assert!(!is_set_start("set_inventory :foo"));
        assert!(!is_set_start("settings :foo"));
        assert!(!is_set_start("dispatch \"X.Y\""));
    }


    #[test]
    fn parses_from_iter_value_spec_in_isolation() {
        let spec = parse_value_spec("from_iter(:strength)").unwrap();
        match spec {
            ValueSpec::FromIter { field } => assert_eq!(field, "strength"),
            other => panic!("expected FromIter, got {:?}", other),
        }
    }



}
