use crate::ir::*;
use crate::parse_blocks::*;
use crate::parser_helpers::*;

/// The value object an inline `one_of` desugars to. One String field named
/// `value`, one member row per admitted value, and closed_set set — identical
/// to what Ruby's AttributeCollector#synthesise_closed_set builds.
fn closed_set_value_object(name: &str, values: &[String]) -> ValueObject {
    ValueObject {
        name: name.to_string(),
        attributes: vec![Attribute {
            name: "value".to_string(),
            r#type: "String".to_string(),
            default: None,
            list: false,
            optional: false,
            enum_values: vec![],
            pattern: None,
            // The synthesised set IS the closed set — its members are right
            // here — so it names no other.
            admits: None,
        }],
        invariants: vec![],
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
        vision: None,
        classification: None,
        aggregates: vec![],
        read_models: vec![],
        policies: vec![],
        process_managers: vec![],
    };

    let source = crate::bluebook::parser_helpers::strip_shebang(source);

    let lines: Vec<&str> = source.lines().collect();
    let mut i = 0;

    while i < lines.len() {
        let line = lines[i].trim();

        if line.starts_with("Hecks.bluebook") {
            if let Some(name) = extract_string(line) {
                domain.name = name;
            }
            crate::bluebook::parse_blocks::assert_text_kwarg("version");
            if let Some(v) = extract_kwarg_string(line, "version") {
                domain.version = Some(v);
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

        if let Some(consumed) = dispatch_block(line, &lines[i..], &mut domain) {
            i += consumed;
            continue;
        }

        i += 1;
    }

    domain
}

/// WHICH WORD, GENERATED ; WHAT HAPPENS WHEN IT MATCHES, HAND-WRITTEN. The
/// four-word list this used to hand-maintain (`aggregate`, `read_model`,
/// `policy`, `process_manager`, each its own `if keyword_matches(...)`) is
/// `bluebook::ir_dispatch_words::BLUEBOOK_WORDS` now — projected from the
/// language's own declared syntax (`Syntax::Keyword`, rows where `opens` is
/// not empty). The word this line starts with can drift from what the
/// language admits ; what building each category MEANS (which Rust function
/// parses it, which field of `Domain` it lands in) cannot be generated
/// without inventing what the language does not say, so that part stays
/// exactly as it was.
fn dispatch_block(line: &str, slice: &[&str], domain: &mut Domain) -> Option<usize> {
    let opens = crate::bluebook::ir_dispatch_words::BLUEBOOK_WORDS
        .iter()
        .find(|(word, _)| keyword_matches(line, word))
        .map(|(_, opens)| *opens)?;

    match opens {
        "Aggregate" => {
            let (agg, nested_policies, consumed) = parse_aggregate(slice);
            domain.aggregates.push(agg);
            domain.policies.extend(nested_policies);
            Some(consumed)
        }
        "ReadModel" => {
            let (model, consumed) = parse_read_model(slice);
            domain.read_models.push(model);
            Some(consumed)
        }
        "Policy" => {
            let (policy, consumed) = parse_policy(slice);
            domain.policies.push(policy);
            Some(consumed)
        }
        "ProcessManager" => {
            let (pm, consumed) = parse_process_manager(slice);
            domain.process_managers.push(pm);
            Some(consumed)
        }
        other => unreachable!("BLUEBOOK_WORDS opens {other:?}, which dispatch_block does not handle"),
    }
}

pub(crate) fn keyword_matches(line: &str, keyword: &str) -> bool {
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

/// `attribute`, `reference_to`, `has_many`, `has_one`, `belongs_to`, and the
/// shorthand forms all push into ONE `agg.attributes`, in the order lines are
/// encountered — matching Ruby's `AttributeCollector`, where every one of
/// them calls the same `attribute()` onto the same array.
///
/// USED TO COLLECT REFERENCES INTO A SEPARATE VECTOR, PREPENDED at the end,
/// on the claim that "the IR has always listed every reference before every
/// declared field". The claim was false, not merely stale : every real
/// aggregate in this corpus happens to write `reference_to` immediately
/// after `identified_by`, before any plain `attribute` — so declaration order
/// and "references first" were the same order every time, and nothing ever
/// told them apart. Ruby's own builder proves it — `attribute :id` then
/// `reference_to Target` then `attribute :label` comes back `[:id,
/// :target_id, :label]`, not references-first. Found by hand-probing
/// `has_many`/`has_one`/`belongs_to` against a bluebook that (reasonably)
/// declared an identity attribute before its relationships.
fn parse_aggregate(lines: &[&str]) -> (Aggregate, Vec<Policy>, usize) {
    let first = lines[0].trim();
    let name = extract_string(first).unwrap_or_default();
    let desc = extract_second_string(first);

    let mut synthesised: Vec<ValueObject> = Vec::new();
    let owner = name.clone();
    let mut agg = Aggregate {
        name,
        description: desc,
        attributes: vec![],
        commands: vec![],
        queries: vec![],
        value_objects: vec![],
        entities: vec![],
        lifecycle: None,
        identified_by: vec![],
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
            // WHICH WORD, GENERATED ; WHAT OPENING IT MEANS, HAND-WRITTEN. Same
            // shape as `dispatch_block` — see its own comment. Three of these
            // five used to be checked with a bare `line.starts_with(literal)`,
            // no word-boundary guard at all ; normalized to `keyword_matches`
            // (the same helper `dispatch_block` already used) now that
            // recognition is one lookup instead of five separate literals. No
            // real bluebook exercises the difference — nothing else in the
            // corpus shares any of these five words as a PREFIX — but a
            // generated table wants one consistent comparison, not five.
            if let Some(opens) = crate::bluebook::ir_dispatch_words::AGGREGATE_WORDS
                .iter()
                .find(|(word, _)| keyword_matches(line, word))
                .map(|(_, opens)| *opens)
            {
                match opens {
                    "Command" => {
                        let (cmd, consumed) = parse_command(&lines[i..], &owner);
                        agg.commands.push(cmd);
                        i += consumed;
                        continue;
                    }
                    "ValueObject" => {
                        let (vo, consumed) = parse_value_object(&lines[i..]);
                        agg.value_objects.push(vo);
                        i += consumed;
                        continue;
                    }
                    "Entity" => {
                        let (ent, consumed) = parse_entity(&lines[i..]);
                        agg.entities.push(ent);
                        i += consumed;
                        continue;
                    }
                    "Query" => {
                        if ends_with_do_block(line) {
                            let (q, consumed) = parse_query(&lines[i..]);
                            agg.queries.push(q);
                            i += consumed;
                            continue;
                        }
                        push_query(line, &mut agg, &mut depth);
                    }
                    "Policy" => {
                        let (policy, consumed) = parse_policy(&lines[i..]);
                        nested_policies.push(policy);
                        i += consumed;
                        continue;
                    }
                    other => unreachable!(
                        "AGGREGATE_WORDS opens {other:?}, which parse_aggregate does not handle"
                    ),
                }
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
                        attr.r#type = type_name;
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
                absorb_reference_to(line, &mut agg.attributes);
            } else if line.starts_with("has_many") {
                absorb_has_many(line, &mut agg.attributes);
            } else if line.starts_with("has_one") {
                absorb_has_one(line, &mut agg.attributes);
            } else if line.starts_with("belongs_to") {
                absorb_belongs_to(line, &mut agg.attributes);
            } else if line.starts_with("lifecycle") {
                let (lc, consumed) = parse_lifecycle(&lines[i..]);
                agg.lifecycle = Some(lc);
                i += consumed;
                continue;
            } else if line.starts_with("identified_by") {
                let (paths, consumed) = extract_identity_paths(&lines[i..]);
                agg.identified_by = paths;
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

    agg.value_objects.extend(synthesised);
    (agg, nested_policies, i + 1)
}

fn absorb_reference_to(line: &str, references: &mut Vec<Attribute>) {
    if let Some(target) = extract_word_after(line, "reference_to") {
        let name = if let Some(pos) = line.find(", as:") {
            let after = &line[pos + ", as:".len()..];
            extract_symbol(after).unwrap_or_else(|| format!("{}_id", crate::naming::snake(&target)))
        } else {
            format!("{}_id", crate::naming::snake(&target))
        };
        references.push(reference_attribute(name, &target, false));
    }
}

/// THE TYPE, UNQUALIFIED. `has_many Billing::Invoices` points at an Invoice ;
/// which chapter it was declared in is not part of the reference's type, and
/// never reached the IR — `Reference<Invoice>` is what both runtimes spell.
fn unqualified_type(token: &str) -> String {
    match token.rsplit_once("::") {
        Some((_, held)) => held.to_string(),
        None => token.to_string(),
    }
}

fn parse_as_alias(line: &str) -> Option<String> {
    line.find(", as:")
        .and_then(|pos| extract_symbol(&line[pos + ", as:".len()..]))
}

fn absorb_has_many(line: &str, references: &mut Vec<Attribute>) {
    if let Some(token) = extract_word_after(line, "has_many") {
        let plural = unqualified_type(&token);
        let target = crate::naming::singularize(&plural);
        let name = parse_as_alias(line).unwrap_or_else(|| crate::naming::snake(&plural));
        references.push(reference_attribute(name, &target, false));
    }
}

fn absorb_has_one(line: &str, references: &mut Vec<Attribute>) {
    if let Some(token) = extract_word_after(line, "has_one") {
        absorb_held(line, &token, references);
    }
}

fn absorb_belongs_to(line: &str, references: &mut Vec<Attribute>) {
    if let Some(token) = extract_word_after(line, "belongs_to") {
        absorb_held(line, &token, references);
    }
}

/// `has_one` and `belongs_to` read IDENTICALLY — one held instance, named for
/// it unless `as:` says otherwise. The two verbs differ in which side owns the
/// key, which is a persistence reading nothing here has ever made: the IR they
/// left was the same reference and the same declared attribute, so they share
/// the one body rather than two that must be kept in step.
///
/// USED TO ALSO PUSH A SECOND ATTRIBUTE onto `agg.attributes` directly — the
/// bare target type, same name, guarded by "unless already present". The
/// guard could never fire : `references` and `agg.attributes` are two
/// separate vectors, only concatenated at the very END of `parse_aggregate`
/// (`references.append(&mut agg.attributes)`), so the just-pushed reference
/// was never visible to a check against `agg.attributes` alone. Every
/// `has_one`/`belongs_to` would have left TWO attributes of the same name —
/// `Reference<Target>` and bare `Target` — and neither runtime nor any test
/// ever exercised the words to notice, because Ruby had not landed them yet.
/// Ruby's `reference_to` (which these are sugar over on that side) produces
/// exactly one attribute ; this now matches it.
fn absorb_held(line: &str, token: &str, references: &mut Vec<Attribute>) {
    let target = unqualified_type(token);
    let name = parse_as_alias(line).unwrap_or_else(|| crate::naming::snake(&target));
    references.push(reference_attribute(name, &target, false));
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
        offset: None,
        cursor: None,
        consistency: None,
        freshness: None,
        authorization: None,
        null_semantics: None,
        inspection: None,
        index_hints: vec![],
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
