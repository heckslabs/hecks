fn absorb_reference_to(line: &str, agg: &mut Aggregate) {
    if line.starts_with("reference_to(") {
        if let Some(r) = parse_shorthand_reference(line) {
            agg.references.push(r);
        }
    } else if let Some(target) = extract_word_after(line, "reference_to") {
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
        // cardinality ; cardinality + kind ride into the IR via the
        // impl helpers added by ImplReference fixture.
        agg.references.push(Reference::single(name, target, None));
    }
}

/// Simple English singularization mirroring the Ruby DSL `singularize` :
/// `ies` -> `y` (len > 3) ; a trailing `s` is dropped (len > 1) ; otherwise
/// unchanged. Used by `has_many Xs` so the collection target aggregate is the
/// singular (Stories -> Story) while the attribute name stays the snake_case
/// plural (Stories -> stories). has_one / belongs_to take the type verbatim.
fn singularize(plural: &str) -> String {
    if plural.len() > 3 && plural.ends_with("ies") {
        format!("{}y", &plural[..plural.len() - 3])
    } else if plural.len() > 1 && plural.ends_with('s') {
        plural[..plural.len() - 1].to_string()
    } else {
        plural.to_string()
    }
}

/// Split a possibly-qualified type token `Domain::Sub::Type` into
/// (domain, target) : domain is the `::`-joined prefix or None, target is the
/// final segment. Mirrors the Ruby builders `type.to_s.split("::")`.
fn split_qualified_type(token: &str) -> (Option<String>, String) {
    match token.rsplit_once("::") {
        Some((dom, t)) => (Some(dom.to_string()), t.to_string()),
        None => (None, token.to_string()),
    }
}

/// Extract the `, as: :alias` override from a relationship line, if present.
/// Mirrors absorb_reference_to + the Ruby builders `as:` kwarg.
fn parse_as_alias(line: &str) -> Option<String> {
    line.find(", as:").and_then(|pos| extract_symbol(&line[pos + ", as:".len()..]))
}

/// `has_many Xs[, as: :alias]` — owner-side collection. The target is the
/// singular of the plural type token ; the attribute name is the `as:` alias
/// or the snake_case plural. Unbounded cardinality (min 0, max None) ; `max:` /
/// `at_least:` are not used in the live corpus and are not parsed here.
fn absorb_has_many(line: &str, agg: &mut Aggregate) {
    if let Some(token) = extract_word_after(line, "has_many") {
        let (domain, plural) = split_qualified_type(&token);
        let target = singularize(&plural);
        let name = parse_as_alias(line).unwrap_or_else(|| to_snake_case(&plural));
        agg.references.push(Reference::many(name, target, domain));
    }
}

/// `has_one X[, as: :alias]` — owner-side single. Target verbatim (no
/// singularization) ; name is the `as:` alias or snake_case target.
fn absorb_has_one(line: &str, agg: &mut Aggregate) {
    if let Some(token) = extract_word_after(line, "has_one") {
        let (domain, target) = split_qualified_type(&token);
        let name = parse_as_alias(line).unwrap_or_else(|| to_snake_case(&target));
        agg.references.push(Reference::has_one(name.clone(), target.clone(), domain));
        // references-not-ids : synthesise a stored FK attribute (the target
        // aggregate name, not a primitive) at declaration order, if absent.
        if !agg.attributes.iter().any(|a| a.name == name) {
            agg.attributes.push(Attribute {
                name,
                attr_type: target,
                default: None,
                list: false,
                required: false,
            });
        }
    }
}

/// `belongs_to X[, as: :alias]` — dependent-side single. IR-equivalent to
/// has_one ; the distinction is authored intent. Target verbatim.
fn absorb_belongs_to(line: &str, agg: &mut Aggregate) {
    if let Some(token) = extract_word_after(line, "belongs_to") {
        let (domain, target) = split_qualified_type(&token);
        let name = parse_as_alias(line).unwrap_or_else(|| to_snake_case(&target));
        agg.references.push(Reference::belongs_to(name.clone(), target.clone(), domain));
        // references-not-ids : synthesise a stored FK attribute (the target
        // aggregate name, not a primitive) at declaration order, if absent.
        if !agg.attributes.iter().any(|a| a.name == name) {
            agg.attributes.push(Attribute {
                name,
                attr_type: target,
                default: None,
                list: false,
                required: false,
            });
        }
    }
}
