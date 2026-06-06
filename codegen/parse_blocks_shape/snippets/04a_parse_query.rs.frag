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
                        required: false,
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

