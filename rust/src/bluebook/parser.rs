use crate::ir::*;
use crate::parse_blocks::*;
use crate::parser_helpers::*;

/// The value object an inline `one_of` desugars to. One String field named
/// `value`, one member row per admitted value, and closed_set set — identical
/// to what Ruby's AttributeCollector#synthesise_closed_set builds.
fn closed_set_value_object(name: &str, values: &[String]) -> ValueObject {
    ValueObject {
        name: name.to_string(),
        description: None,
        attributes: vec![Attribute {
            name: "value".to_string(),
            attr_type: "String".to_string(),
            default: None,
            list: false,
            optional: false,
            enum_values: vec![],
            pattern: None,
        }],
        invariants: vec![],
        derivations: vec![],
        members: values
            .iter()
            .map(|value| vec![("value".to_string(), value.clone())])
            .collect(),
        closed_set: true,
    }
}

pub fn parse(source: &str) -> Domain {
    let mut domain = Domain {
        name: String::new(),
        version: None,
        category: None,
        vision: None,
        classification: None,
        aggregates: vec![],
        read_models: vec![],
        policies: vec![],
        fixtures: vec![],
        entrypoint: None,
        sections: vec![],
        process_managers: vec![],
        cadences: vec![],
        block_grammars: vec![],
    };

    let source = strip_shebang(source);
    let grammar = BlockGrammar::canonical_bluebook();

    let lines: Vec<&str> = source.lines().collect();
    let mut i = 0;

    while i < lines.len() {
        let line = lines[i].trim();

        if line.starts_with("Hecks.bluebook") {
            if let Some(name) = extract_string(line) {
                domain.name = name;
            }
            if let Some(v) = extract_kwarg_string(line, "version") {
                domain.version = Some(v);
            }
        }

        if line.starts_with("category") && !line.starts_with("category,") {
            if let Some(cat) = extract_string(line) {
                domain.category = Some(cat);
            }
        }

        if line.starts_with("vision") {
            let (v, consumed) = extract_string_spanning(&lines, i);
            if let Some(v) = v {
                domain.vision = Some(v);
            }
            i += consumed;
            continue;
        }

        if line == "core" || line == "supporting" || line == "generic" {
            domain.classification = Some(line.to_string());
        }

        if line.starts_with("entrypoint") {
            if let Some(ep) = extract_string(line) {
                domain.entrypoint = Some(ep);
            }
        }

        if line.starts_with("block_grammar") {
            let (bg, consumed) = parse_block_grammar(&lines[i..]);
            domain.block_grammars.push(bg);
            i += consumed;
            continue;
        }

        if let Some(consumed) = dispatch_block(line, &lines[i..], &grammar, &mut domain) {
            i += consumed;
            continue;
        }

        i += 1;
    }

    domain
}

fn dispatch_block(
    line: &str,
    slice: &[&str],
    grammar: &BlockGrammar,
    domain: &mut Domain,
) -> Option<usize> {
    for entry in &grammar.blocks {
        if !keyword_matches(line, &entry.keyword) {
            continue;
        }
        return Some(invoke(entry.parser, slice, domain));
    }
    None
}

fn keyword_matches(line: &str, keyword: &str) -> bool {
    if !line.starts_with(keyword) {
        return false;
    }
    let after = &line[keyword.len()..];
    if after.is_empty() {
        return true;
    }
    let next = after.as_bytes()[0];
    !(next as char).is_alphanumeric() && next != b'_'
}

fn invoke(parser: BlockParser, slice: &[&str], domain: &mut Domain) -> usize {
    match parser {
        BlockParser::Aggregate => {
            let (mut agg, nested_policies, consumed) = parse_aggregate(slice);
            if !domain.name.is_empty() {
                agg.context = Some(domain.name.clone());
            }
            if domain.category.is_some() {
                agg.category = domain.category.clone();
            }
            if domain.version.is_some() {
                agg.bluebook_version = domain.version.clone();
            }
            domain.aggregates.push(agg);
            domain.policies.extend(nested_policies);
            consumed
        }
        BlockParser::ReadModel => {
            let (model, consumed) = parse_read_model(slice);
            domain.read_models.push(model);
            consumed
        }
        BlockParser::Section => {
            let (sec, consumed) = parse_section(slice);
            domain.sections.push(sec);
            consumed
        }
        BlockParser::Policy => {
            let (policy, consumed) = parse_policy(slice);
            domain.policies.push(policy);
            consumed
        }
        BlockParser::ProcessManager => {
            let (pm, consumed) = parse_process_manager(slice);
            domain.process_managers.push(pm);
            consumed
        }
        BlockParser::Cadence => {
            let (cad, consumed) = parse_cadence(slice);
            domain.cadences.push(cad);
            consumed
        }
        BlockParser::Fixture => consume_do_block(slice),
    }
}

fn consume_do_block(lines: &[&str]) -> usize {
    let first = lines.first().map(|l| l.trim()).unwrap_or("");
    if !ends_with_do_block(first) {
        return 1;
    }
    let mut depth = 1usize;
    let mut i = 0;
    while i + 1 < lines.len() && depth > 0 {
        i += 1;
        let l = lines[i].trim();
        if l == "end" {
            depth -= 1;
        } else if ends_with_do_block(l) {
            depth += 1;
        }
    }
    i + 1
}

pub fn parse_block_grammar(lines: &[&str]) -> (BlockGrammar, usize) {
    let first = lines[0].trim();
    let name = extract_string(first).unwrap_or_default();
    let mut bg = BlockGrammar {
        name,
        blocks: vec![],
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
        if depth == 1 && line.starts_with("block ") {
            if let Some(entry) = parse_block_grammar_line(line) {
                bg.blocks.push(entry);
            }
        } else if ends_with_do_block(line) {
            depth += 1;
        }
        i += 1;
    }
    (bg, i + 1)
}

fn parse_block_grammar_line(line: &str) -> Option<BlockGrammarEntry> {
    let keyword = extract_string(line)?;
    let pos = line.find("parser:")?;
    let after = line[pos + "parser:".len()..].trim();
    let parser_name = if after.starts_with(':') {
        after
            .trim_start_matches(':')
            .split(|c: char| c == ',' || c.is_whitespace())
            .next()
            .unwrap_or("")
            .to_string()
    } else if after.starts_with('"') {
        extract_string(after)?
    } else {
        after
            .split(|c: char| c == ',' || c.is_whitespace())
            .next()
            .unwrap_or("")
            .to_string()
    };
    let parser = BlockParser::from_name(&parser_name)?;
    Some(BlockGrammarEntry { keyword, parser })
}

pub fn strip_shebang(source: &str) -> &str {
    if source.starts_with("#!") {
        if let Some(nl) = source.find('\n') {
            return &source[nl + 1..];
        }
        return "";
    }
    source
}

fn parse_aggregate(lines: &[&str]) -> (Aggregate, Vec<Policy>, usize) {
    let first = lines[0].trim();
    let name = extract_string(first).unwrap_or_default();
    let desc = extract_second_string(first);

    let mut synthesised: Vec<ValueObject> = Vec::new();
    let mut agg = Aggregate {
        name,
        description: desc,
        context: None,
        category: None,
        bluebook_version: None,
        realm_path: None,
        attributes: vec![],
        factories: vec![],
        commands: vec![],
        queries: vec![],
        value_objects: vec![],
        entities: vec![],
        references: vec![],
        lifecycle: None,
        identified_by: None,
        invariants: vec![],
        views: vec![],
        unknown_keywords: vec![],
    };

    let mut nested_policies: Vec<Policy> = vec![];

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
            if line.starts_with("factory ") || line.starts_with("create ") {
                let (factory, consumed) = parse_factory(&lines[i..]);
                agg.factories.push(factory);
                i += consumed;
                continue;
            } else if line.starts_with("command") || is_shorthand_command(line) {
                let (cmd, consumed) = parse_command(&lines[i..]);
                agg.commands.push(cmd);
                i += consumed;
                continue;
            } else if line.starts_with("value_object") {
                let (vo, consumed) = parse_value_object(&lines[i..]);
                agg.value_objects.push(vo);
                i += consumed;
                continue;
            } else if line.starts_with("entity") {
                let (ent, consumed) = parse_entity(&lines[i..]);
                agg.entities.push(ent);
                i += consumed;
                continue;
            } else if line.starts_with("attribute") {
                if let Some(mut attr) = parse_attribute(line) {
                    // An inline closed set desugars to a value object named for
                    // the attribute — the same shape a hand-written one_of
                    // builds, so it goes through the same machinery and the
                    // attribute's type is still a DECLARED value object.
                    //
                    // This used to be parsed and thrown away : the attribute
                    // became a plain String and the closed set meant nothing.
                    if !attr.enum_values.is_empty() {
                        let type_name = crate::naming::pascal(&attr.name);
                        // deferred to the END of the aggregate, not pushed here.
                        // Ruby appends synthesised shapes at build, so pushing
                        // at the point of declaration put them in a different
                        // ORDER and split parity — the same bluebook has to
                        // yield the same IR, field for field and index for index.
                        synthesised.push(closed_set_value_object(&type_name, &attr.enum_values));
                        attr.attr_type = type_name;
                        attr.enum_values = vec![];
                    }
                    agg.attributes.push(attr);
                }
                if ends_with_do_block(line) {
                    let (lc, consumed) = parse_lifecycle(&lines[i..]);
                    if !lc.transitions.is_empty() {
                        agg.lifecycle = Some(lc);
                    }
                    i += consumed;
                    continue;
                }
            } else if line.starts_with("description") {
                agg.description = extract_string(line);
            } else if line.starts_with("reference_to") {
                absorb_reference_to(line, &mut agg);
            } else if line.starts_with("has_many") {
                absorb_has_many(line, &mut agg);
            } else if line.starts_with("has_one") {
                absorb_has_one(line, &mut agg);
            } else if line.starts_with("belongs_to") {
                absorb_belongs_to(line, &mut agg);
            } else if line.starts_with("lifecycle") {
                let (lc, consumed) = parse_lifecycle(&lines[i..]);
                agg.lifecycle = Some(lc);
                i += consumed;
                continue;
            } else if line.starts_with("invariant") {
                let (inv, consumed) = parse_invariant(&lines[i..]);
                if let Some(inv) = inv {
                    agg.invariants.push(inv);
                }
                i += consumed;
                continue;
            } else if line.starts_with("identified_by") {
                agg.identified_by = extract_identity_path(line);
            } else if line.starts_with("view") && ends_with_do_block(line) {
                let (v, consumed) = parse_view(&lines[i..]);
                agg.views.push(v);
                i += consumed;
                continue;
            } else if is_shorthand_line(line) {
                absorb_shorthand(line, &mut agg);
            } else if line.starts_with("query") {
                if ends_with_do_block(line) {
                    let (q, consumed) = parse_query(&lines[i..]);
                    agg.queries.push(q);
                    i += consumed;
                    continue;
                }
                push_query(line, &mut agg, &mut depth);
            } else if line.starts_with("rule ") || line.starts_with("rule\t") {
                let consumed = consume_rule_block(&lines[i..]);
                i += consumed;
                continue;
            } else if line.starts_with("policy ") || line.starts_with("policy\t") {
                let (policy, consumed) = parse_policy(&lines[i..]);
                nested_policies.push(policy);
                i += consumed;
                continue;
            } else if ends_with_do_block(line) {
                let word = line.split_whitespace().next().unwrap_or("");
                if let Some(suggestion) = suggest_block_keyword(word) {
                    agg.unknown_keywords.push(crate::ir::UnknownKeyword {
                        keyword: word.to_string(),
                        suggestion,
                    });
                }
                depth += 1;
            }
        } else if ends_with_do_block(line) {
            depth += 1;
        }

        i += 1;
    }

    agg.value_objects.extend(synthesised);
    (agg, nested_policies, i + 1)
}

const BLOCK_KEYWORDS: &[&str] = &[
    "command",
    "query",
    "value_object",
    "entity",
    "invariant",
    "view",
    "rule",
    "policy",
    "factory",
    "lifecycle",
    "create",
];

fn suggest_block_keyword(word: &str) -> Option<String> {
    if word.is_empty() || BLOCK_KEYWORDS.contains(&word) {
        return None;
    }
    BLOCK_KEYWORDS
        .iter()
        .map(|kw| (*kw, levenshtein(word, kw)))
        .filter(|(_, d)| *d <= 2)
        .min_by_key(|(_, d)| *d)
        .map(|(kw, _)| kw.to_string())
}

fn levenshtein(a: &str, b: &str) -> usize {
    let a: Vec<char> = a.chars().collect();
    let b: Vec<char> = b.chars().collect();
    let mut prev: Vec<usize> = (0..=b.len()).collect();
    let mut cur = vec![0usize; b.len() + 1];
    for (i, ca) in a.iter().enumerate() {
        cur[0] = i + 1;
        for (j, cb) in b.iter().enumerate() {
            let cost = if ca == cb { 0 } else { 1 };
            cur[j + 1] = (prev[j + 1] + 1).min(cur[j] + 1).min(prev[j] + cost);
        }
        std::mem::swap(&mut prev, &mut cur);
    }
    prev[b.len()]
}

fn absorb_reference_to(line: &str, agg: &mut Aggregate) {
    if line.starts_with("reference_to(") {
        if let Some(r) = parse_shorthand_reference(line) {
            agg.references.push(r);
        }
    } else if let Some(target) = extract_word_after(line, "reference_to") {
        let name = if let Some(pos) = line.find(", as:") {
            let after = &line[pos + ", as:".len()..];
            extract_symbol(after).unwrap_or_else(|| format!("{}_id", crate::naming::snake(&target)))
        } else if let Some(pos) = line.find(", role:") {
            let after = &line[pos + ", role:".len()..];
            extract_symbol(after).unwrap_or_else(|| format!("{}_id", crate::naming::snake(&target)))
        } else {
            format!("{}_id", crate::naming::snake(&target))
        };
        agg.references.push(Reference::single(name, target, None));
    }
}

fn singularize(plural: &str) -> String {
    if plural.len() > 3 && plural.ends_with("ies") {
        format!("{}y", &plural[..plural.len() - 3])
    } else if plural.len() > 1 && plural.ends_with('s') {
        plural[..plural.len() - 1].to_string()
    } else {
        plural.to_string()
    }
}

fn split_qualified_type(token: &str) -> (Option<String>, String) {
    match token.rsplit_once("::") {
        Some((dom, t)) => (Some(dom.to_string()), t.to_string()),
        None => (None, token.to_string()),
    }
}

fn parse_as_alias(line: &str) -> Option<String> {
    line.find(", as:")
        .and_then(|pos| extract_symbol(&line[pos + ", as:".len()..]))
}

fn parse_from_context(line: &str) -> Option<String> {
    line.find("from:").and_then(|pos| {
        line[pos + "from:".len()..]
            .split_whitespace()
            .next()
            .map(|s| s.trim_matches(',').to_string())
            .filter(|s| !s.is_empty())
    })
}

fn absorb_has_many(line: &str, agg: &mut Aggregate) {
    if let Some(token) = extract_word_after(line, "has_many") {
        let (split_domain, plural) = split_qualified_type(&token);
        let domain = parse_from_context(line).or(split_domain);
        let target = singularize(&plural);
        let name = parse_as_alias(line).unwrap_or_else(|| crate::naming::snake(&plural));
        agg.references.push(Reference::many(name, target, domain));
    }
}

fn absorb_has_one(line: &str, agg: &mut Aggregate) {
    if let Some(token) = extract_word_after(line, "has_one") {
        let (split_domain, target) = split_qualified_type(&token);
        let domain = parse_from_context(line).or(split_domain);
        let name = parse_as_alias(line).unwrap_or_else(|| crate::naming::snake(&target));
        agg.references
            .push(Reference::has_one(name.clone(), target.clone(), domain));
        if !agg.attributes.iter().any(|a| a.name == name) {
            agg.attributes.push(Attribute {
                name,
                attr_type: target,
                default: None,
                list: false,
                optional: false,
                enum_values: vec![],
                pattern: None,
            });
        }
    }
}

fn absorb_belongs_to(line: &str, agg: &mut Aggregate) {
    if let Some(token) = extract_word_after(line, "belongs_to") {
        let (split_domain, target) = split_qualified_type(&token);
        let domain = parse_from_context(line).or(split_domain);
        let name = parse_as_alias(line).unwrap_or_else(|| crate::naming::snake(&target));
        agg.references
            .push(Reference::belongs_to(name.clone(), target.clone(), domain));
        if !agg.attributes.iter().any(|a| a.name == name) {
            agg.attributes.push(Attribute {
                name,
                attr_type: target,
                default: None,
                list: false,
                optional: false,
                enum_values: vec![],
                pattern: None,
            });
        }
    }
}
fn absorb_shorthand(line: &str, agg: &mut Aggregate) {
    match parse_shorthand(line) {
        ShorthandResult::Attribute(a) => agg.attributes.push(a),
        ShorthandResult::Reference(r) => agg.references.push(r),
        ShorthandResult::None => {}
    }
}

fn push_query(line: &str, agg: &mut Aggregate, depth: &mut usize) {
    let name = extract_string(line).unwrap_or_else(|| {
        line.split_whitespace()
            .nth(1)
            .unwrap_or("")
            .trim_matches('"')
            .to_string()
    });
    let desc = extract_second_string(line);
    agg.queries.push(Query {
        name,
        description: desc,
        attributes: vec![],
        wheres: vec![],
        order_by: None,
        limit: None,
        reduction: None,
        group_by: None,
        scope_to: None,
    });
    if ends_with_do_block(line) {
        *depth += 1;
    }
}

#[allow(dead_code)]
fn needs_continuation(s: &str) -> bool {
    let trimmed = s.trim_end();
    if trimmed.ends_with(',') {
        return true;
    }
    let mut depth = 0i32;
    let mut in_str = false;
    let mut prev = '\0';
    for c in s.chars() {
        match c {
            '"' if prev != '\\' => in_str = !in_str,
            '[' | '{' | '(' if !in_str => depth += 1,
            ']' | '}' | ')' if !in_str => depth -= 1,
            _ => {}
        }
        prev = c;
    }
    depth > 0
}
