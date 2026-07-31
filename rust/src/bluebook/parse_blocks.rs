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
                model.aggregate_heads.push(AggregateHead { aggregate, name, many });
            }
        }
        i += 1;
    }
    (model, i + 1)
}

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
            if depth == 0 {
                break;
            }
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
        let end = tail
            .find(|c: char| !c.is_alphanumeric() && c != '_')
            .unwrap_or(tail.len());
        let f = tail[..end].trim();
        if f.is_empty() {
            return None;
        }
        f.to_string()
    };
    Some(SectionRow { label, field })
}

pub fn parse_command(lines: &[&str]) -> (Command, usize) {
    let first = lines[0].trim();
    let name = extract_string(first)
        .unwrap_or_else(|| first.split_whitespace().next().unwrap_or("").to_string());

    let mut cmd = Command {
        name,
        description: None,
        role: None,
        attributes: vec![],
        references: vec![],
        emits: None,
        emits_identified_by: None,
        givens: vec![],
        mutations: vec![],
        redirects_native: vec![],
    };

    if first.contains("{") && first.contains("}") {
        parse_inline_command(first, &mut cmd);
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
                    ShorthandResult::Reference(r) => cmd.references.push(r),
                    ShorthandResult::None => {}
                }
            } else if line.starts_with("role") {
                cmd.role = parse_role_arg(line);
            } else if line.starts_with("goal") || line.starts_with("description") {
                cmd.description = extract_string(line);
            } else if line.starts_with("emits") {
                cmd.emits = extract_string(line);
                cmd.emits_identified_by = extract_kwarg_symbol(line, "identified_by");
            } else if line.starts_with("redirects_native") {
                cmd.redirects_native = line
                    .split('"')
                    .skip(1)
                    .step_by(2)
                    .map(|s| s.to_string())
                    .collect();
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
                    cmd.references.push(Reference::single(name, target, None));
                }
            } else if line.starts_with("given") && line.contains(" do ") && line.ends_with("end") {
                let msg = extract_string(line);
                if let (Some(do_pos), Some(stripped)) =
                    (inline_do_pos(line), line.strip_suffix("end"))
                {
                    let expr = stripped[do_pos + " do ".len()..].trim().to_string();
                    if !expr.is_empty() {
                        cmd.givens.push(Given {
                            expression: expr,
                            message: msg,
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
                let expr = body.join(" && ");
                if !expr.is_empty() {
                    cmd.givens.push(Given {
                        expression: expr,
                        message: msg,
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
                    expression: expr,
                    message: msg,
                });
            } else if line.starts_with("then_set") {
                if let Some(m) = parse_mutation(line) {
                    cmd.mutations.push(m);
                }
            } else if line.starts_with("then_toggle") {
                if let Some(field) = extract_symbol(line) {
                    cmd.mutations.push(Mutation {
                        field,
                        operation: MutationOp::Toggle,
                        value: String::new(),
                        invalid_op: None,
                    });
                }
            } else if line.starts_with("then_delete") {
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

fn extract_produces(first: &str) -> Option<String> {
    let pos = first.find("produces:")?;
    let after = first[pos + "produces:".len()..].trim_start();
    let end = after
        .find(|c: char| !(c.is_alphanumeric() || c == '_' || c == ':'))
        .unwrap_or(after.len());
    let token = after[..end].trim().trim_end_matches(':');
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
                cmd.emits = extract_string(part);
                cmd.emits_identified_by = extract_kwarg_symbol(part, "identified_by");
            } else if part.starts_with("attribute") {
                if let Some(attr) = parse_attribute(part) {
                    cmd.attributes.push(attr);
                }
            } else if part.starts_with("reference_to") {
                if let Some(target) = extract_word_after(part, "reference_to") {
                    let snake = crate::naming::snake(&target);
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
        reduction: None,
        group_by: None,
        scope_to: None,
    };

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
                        optional: false,
                        enum_values: vec![],
                        pattern: None,
                        hint: None,
                        logged: true,
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
            } else if line == "count" || line.starts_with("count ") || line.starts_with("count\t") {
                q.reduction = Some(Reduction::Count);
            } else if line.starts_with("sum") {
                if let Some(f) = extract_symbol(line) {
                    q.reduction = Some(Reduction::Sum(f));
                }
            } else if line.starts_with("median") {
                if let Some(f) = extract_symbol(line) {
                    q.reduction = Some(Reduction::Median(f));
                }
            } else if line.starts_with("max") {
                if let Some(f) = extract_symbol(line) {
                    q.reduction = Some(Reduction::Max(f));
                }
            } else if line.starts_with("min") {
                if let Some(f) = extract_symbol(line) {
                    q.reduction = Some(Reduction::Min(f));
                }
            } else if line.starts_with("group_by") {
                if let Some(f) = extract_symbol(line) {
                    q.group_by = Some(f);
                }
            } else if line.starts_with("scope_to") {
                if let Some(f) = extract_symbol(line) {
                    q.scope_to = Some(f);
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
        "none_in_state" => WhereOp::NoneInState,
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

fn parse_derive_signature(header: &str) -> Option<(String, String)> {
    let sig = header.trim();
    let comma = sig.find(',')?;
    let name = sig[..comma].trim().trim_start_matches(':').to_string();
    let rtype = sig[comma + 1..].trim().to_string();
    if name.is_empty() || rtype.is_empty() {
        return None;
    }
    Some((name, rtype))
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
    let mut vo = ValueObject {
        name,
        description: None,
        attributes: vec![],
        invariants: vec![],
        derivations: vec![],
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
                        name: inv_name,
                        expression: expr.to_string(),
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
                        name: inv_name,
                        expression: expr.to_string(),
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
                    name: inv_name,
                    expression: body.join(" && "),
                });
            }
            i = j + 1;
            continue;
        } else if depth == 1
            && line.starts_with("derive")
            && line.contains(" do ")
            && line.ends_with("end")
        {
            if let (Some(do_pos), Some(stripped)) = (line.find(" do "), line.strip_suffix("end")) {
                let header = &line["derive".len()..do_pos];
                if let Some((name, rtype)) = parse_derive_signature(header) {
                    let raw_body = stripped[do_pos + " do ".len()..].trim();
                    let (params, expr) = split_block_params(raw_body);
                    if !expr.is_empty() {
                        vo.derivations.push(Derivation {
                            name,
                            return_type: rtype,
                            params,
                            expression: expr.to_string(),
                        });
                    }
                }
            }
        } else if depth == 1 && line.starts_with("derive") && ends_with_do_block(line) {
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
            if let Some((name, rtype)) = parse_derive_signature(header) {
                if !body.is_empty() {
                    vo.derivations.push(Derivation {
                        name,
                        return_type: rtype,
                        params,
                        expression: body.join(" && "),
                    });
                }
            }
            i = j + 1;
            continue;
        } else if ends_with_do_block(line) {
            depth += 1;
        }
        if depth == 1 {
            if line.starts_with("description") {
                vo.description = extract_string(line);
            }
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
            if depth == 0 {
                break;
            }
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
                ent.identified_by = extract_identity_path(line);
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
    let mut with: Vec<(String, crate::ir::ValueSpec)> = vec![];
    let mut wheres: Vec<crate::ir::WhereClause> = vec![];
    let mut for_each: Option<crate::ir::ForEachSpec> = None;
    let mut extra_dispatches: Vec<crate::ir::DispatchSpec> = vec![];

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
        if line.starts_with("with") {
            if let (Some(key), Some(value)) = (extract_string(line), extract_second_string(line)) {
                with.push((key, crate::ir::ValueSpec::Literal { value }));
            }
        }
        if line.starts_with("map ") {
            let body = line.strip_prefix("map").unwrap_or("").trim();
            for pair in split_member_pairs(body) {
                if let Some(colon) = pair.find(':') {
                    let key = pair[..colon].trim().to_string();
                    let raw_val = pair[colon + 1..].trim();
                    if key.is_empty() || raw_val.is_empty() {
                        continue;
                    }
                    let spec = if let Some(sym) = raw_val.strip_prefix(':') {
                        crate::ir::ValueSpec::FromEvent {
                            name: sym.trim().to_string(),
                            default: None,
                        }
                    } else if raw_val.starts_with('"') || raw_val.starts_with('\'') {
                        crate::ir::ValueSpec::Literal {
                            value: extract_string(raw_val).unwrap_or_default(),
                        }
                    } else {
                        crate::ir::ValueSpec::Literal {
                            value: raw_val.trim_matches(',').trim().to_string(),
                        }
                    };
                    with.push((key, spec));
                }
            }
        }
        if line.starts_with("where") {
            for w in parse_where_line(line, &[]) {
                wheres.push(w);
            }
        }
        if line.starts_with("for_each") {
            if let Some(fe) = parse_for_each_clause(line) {
                for_each = Some(fe);
            }
        }
        if is_dispatch_start(line) {
            if let Some(ds) = parse_dispatch_statement(line) {
                extra_dispatches.push(ds);
            }
        }
        i += 1;
    }
    (
        Policy {
            name,
            on_event,
            trigger_command: trigger,
            target_domain,
            with,
            wheres,
            for_each,
            extra_dispatches,
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
    let hint = parse_hint_kwarg(line);
    let logged = !(line.contains("logged:")
        && extract_after(line, "logged:")
            .map(|a| a.trim_start().starts_with("false"))
            .unwrap_or(false));
    Some(Attribute {
        name,
        attr_type,
        default,
        list,
        optional,
        enum_values,
        pattern,
        hint,
        logged,
    })
}

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
                rejection.construct,
                body,
                line.trim(),
                rejection.reason,
            );
            None
        }
    }
}

fn parse_hint_kwarg(line: &str) -> Option<String> {
    let after = line.split("hint:").nth(1)?.trim_start();
    let quote = after.chars().next().filter(|c| *c == '"' || *c == '\'')?;
    let body: String = after[quote.len_utf8()..]
        .chars()
        .take_while(|c| *c != quote)
        .collect();
    if body.is_empty() {
        None
    } else {
        Some(body)
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

pub fn parse_fixture(line: &str) -> Fixture {
    let aggregate_name = extract_string(line).unwrap_or_default();
    let mut attributes = vec![];

    if let Some(comma_pos) = line.find(',') {
        let rest = &line[comma_pos + 1..];
        for part in split_top_level_commas(rest) {
            let part = part.trim();
            if let Some(colon) = part.find(':') {
                let key = part[..colon].trim().to_string();
                let raw = part[colon + 1..].trim();
                let val = if raw.starts_with('"') {
                    extract_string(raw).unwrap_or_else(|| raw.to_string())
                } else {
                    raw.to_string()
                };
                attributes.push((key, val));
            }
        }
    }

    Fixture {
        name: None,
        aggregate_name,
        attributes,
    }
}

pub fn parse_fixture_block_body(lines: &[&str]) -> (String, Vec<(String, String)>, usize) {
    let mut aggregate_name = String::new();
    let mut attributes: Vec<(String, String)> = vec![];
    let mut depth = 1usize;
    let mut i = 0;
    while i < lines.len() && depth > 0 {
        let l = lines[i].trim();
        if l == "end" {
            depth -= 1;
            if depth == 0 {
                i += 1;
                break;
            }
        } else if ends_with_do_block(l) {
            depth += 1;
        } else if depth == 1 && !l.is_empty() && !l.starts_with('#') {
            let token_end = l.find(|c: char| c.is_whitespace()).unwrap_or(l.len());
            let key = &l[..token_end];
            let rest = l[token_end..].trim();
            if key == "aggregate" {
                aggregate_name = extract_string(rest).unwrap_or_default();
            } else if !key.is_empty() && key.chars().next().is_some_and(|c| c.is_ascii_lowercase())
            {
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
                    field,
                    operation: MutationOp::Set,
                    value: String::new(),
                    invalid_op: Some(raw[..end].to_string()),
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
        field,
        operation: op,
        value,
        invalid_op: None,
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
                            } else if is_set_start(&joined) {
                                if let Some((attr, spec)) = parse_set_statement(&joined) {
                                    h.set_specs.push((attr, spec));
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
        set_specs: vec![],
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

fn parse_set_statement(line: &str) -> Option<(String, ValueSpec)> {
    let trimmed = line.trim();
    if !is_set_start(trimmed) {
        return None;
    }
    let rest = trimmed[3..].trim_start();
    let comma = rest.find(',')?;
    let attr_raw = rest[..comma].trim();
    let attr = attr_raw
        .trim_matches(|c| c == '"' || c == '\'' || c == ':')
        .to_string();
    if attr.is_empty() {
        return None;
    }
    let val_raw = rest[comma + 1..].trim();
    let spec = parse_value_spec(val_raw)?;
    Some((attr, spec))
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

    let for_each = parse_for_each_clause(tail);

    Some(DispatchSpec {
        command_name,
        with_spec,
        for_each,
    })
}

pub(crate) fn parse_for_each_clause(tail: &str) -> Option<ForEachSpec> {
    let pos = tail.find("for_each:")?;
    let after = &tail[pos + "for_each:".len()..];
    let open = after.find('{')?;
    let close = match_close_brace(&after[open..])? + open;
    let body = after[open + 1..close].trim();
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
    if source_aggregate.contains("::") {
        let full = source_aggregate.clone();
        let segs: Vec<&str> = full.split("::").collect();
        let n = segs.len();
        source_aggregate = segs[n - 1].to_string();
        source_context = Some(segs[n - 2].to_string());
    }
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
    Some(ForEachSpec {
        source_context,
        source_aggregate,
        query_name,
        query_inputs,
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
            if depth == 0 {
                break;
            }
            i += 1;
            continue;
        }

        if depth == 1 {
            if line.starts_with("every") {
                if let Some(s) = extract_string(line) {
                    cad.interval = s;
                }
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
                if key.is_empty() || value.is_empty() {
                    None
                } else {
                    Some((key, value))
                }
            })
            .collect();
    }
    Some(CadenceDispatch {
        command_name,
        attrs,
    })
}

fn split_top_level_cadence(s: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let mut buf = String::new();
    let mut depth: i32 = 0;
    let mut in_str = false;
    let mut prev = '\0';
    for c in s.chars() {
        match c {
            '"' if prev != '\\' => {
                in_str = !in_str;
                buf.push(c);
            }
            '[' | '{' | '(' if !in_str => {
                depth += 1;
                buf.push(c);
            }
            ']' | '}' | ')' if !in_str => {
                depth -= 1;
                buf.push(c);
            }
            ',' if !in_str && depth == 0 => {
                out.push(buf.trim().to_string());
                buf.clear();
            }
            _ => buf.push(c),
        }
        prev = c;
    }
    if !buf.trim().is_empty() {
        out.push(buf.trim().to_string());
    }
    out
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

pub fn parse_view(lines: &[&str]) -> (View, usize) {
    let first = lines[0].trim();
    let name = extract_string(first).unwrap_or_default();
    let mut v = View {
        name,
        show_all: false,
        fields: vec![],
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
            if line == "show_all" || line.starts_with("show_all ") {
                v.show_all = true;
            } else if line.starts_with("show") || line.starts_with("plus") {
                let mut buf = String::new();
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

fn absorb_view_fields(tail: &str, fields: &mut Vec<String>) {
    for raw in tail.split(',') {
        let part = raw.trim().trim_end_matches(',').trim();
        if part.is_empty() {
            continue;
        }
        if part.ends_with(':') {
            continue;
        }
        if !part.starts_with(':') {
            continue;
        }
        let name = part.trim_start_matches(':').to_string();
        if !name.is_empty() {
            fields.push(name);
        }
    }
}

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
            if depth == 0 {
                break;
            }
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
        (false, Some(expr)) => (
            Some(Invariant {
                name,
                expression: expr,
            }),
            consumed,
        ),
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
    fn parses_set_with_literal() {
        let (attr, spec) = parse_set_statement(r#"set :carrying, "body""#).unwrap();
        assert_eq!(attr, "carrying");
        assert!(matches!(spec, ValueSpec::Literal { ref value } if value == "body"));
    }

    #[test]
    fn parses_set_with_from_event() {
        let (attr, spec) =
            parse_set_statement(r#"set :steering_target, from_event(:target)"#).unwrap();
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
        let (attr, spec) = parse_set_statement(r#"set "carrying", "body""#).unwrap();
        assert_eq!(attr, "carrying");
        assert!(matches!(spec, ValueSpec::Literal { ref value } if value == "body"));
    }

    #[test]
    fn rejects_malformed_set_lines() {
        assert!(parse_set_statement("set :carrying").is_none());
        assert!(parse_set_statement(r#"set :, "body""#).is_none());
        assert!(parse_set_statement(r#"dispatch "X.Y""#).is_none());
    }

    #[test]
    fn parses_bare_dispatch_carries_no_for_each() {
        let s = parse_dispatch_statement(r#"dispatch "Body.WakeUp""#).unwrap();
        assert!(
            s.for_each.is_none(),
            "bare dispatch must leave for_each None"
        );
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
        assert!(
            fe.query_inputs.is_empty(),
            "no where: -> empty query_inputs"
        );
    }

    #[test]
    fn parses_for_each_where_binds_query_inputs_from_event() {
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
        let line = r#"dispatch "X.Y", for_each: { from: "cold" }"#;
        let s = parse_dispatch_statement(line).unwrap();
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
            h.set_specs
                .iter()
                .map(|(k, _)| k.as_str())
                .collect::<Vec<_>>(),
            vec!["steering_target", "carrying", "tick"]
        );
        match &h.set_specs[2].1 {
            ValueSpec::FromPm { name, default } => {
                assert_eq!(name, "tick");
                assert_eq!(default.as_deref(), Some("0"));
            }
            other => panic!("expected FromPm, got {:?}", other),
        }
        assert_eq!(h.dispatches.len(), 1);
        assert_eq!(h.dispatches[0].command_name, "Body.Steer");
    }
}
