//! Bluebook parser — reads .bluebook files into IR
//!
//! Parses the Ruby-hosted DSL by pattern matching on the structure.
//! Not a full Ruby parser — just enough to read Bluebook declarations.
//! Block parsers live in parse_blocks.rs.
//!
//! [antibody-exempt: parser.rs — kernel-surface bluebook parser;
//!  storehouse specialize parser regenerates this file byte-for-byte from
//!  parser_shape fixtures. Edit here seeds the golden fixture; update
//!  parser_shape to match. Subsumes unique:true singleton pattern via
//!  identified_by natural-key dispatch.]

use crate::ir::*;
use crate::parser_helpers::*;
use crate::parse_blocks::*;

pub fn parse(source: &str) -> Domain {
    let mut domain = Domain {
        name: String::new(),
        category: None,
        vision: None,
        aggregates: vec![],
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
        }

        if line.starts_with("category") && !line.starts_with("category,") {
            if let Some(cat) = extract_string(line) {
                domain.category = Some(cat);
            }
        }

        if line.starts_with("vision") {
            if let Some(v) = extract_string(line) {
                domain.vision = Some(v);
            }
        }

        if line.starts_with("entrypoint") {
            if let Some(ep) = extract_string(line) {
                domain.entrypoint = Some(ep);
            }
        }

        // i218 — block_grammar is itself parsed inline at the top level
        // so a bluebook can declare its own grammar (e.g. an extension
        // bluebook adding new keywords). Authored grammars accumulate
        // on `domain.block_grammars` ; the parser of THIS source still
        // walks the canonical grammar (chicken-and-egg : you can't
        // reparse with the freshly-declared grammar mid-stream).
        if line.starts_with("block_grammar") {
            let (bg, consumed) = parse_block_grammar(&lines[i..]);
            domain.block_grammars.push(bg);
            i += consumed;
            continue;
        }

        // Walk the block_grammar registry. First keyword whose prefix
        // matches the line claims it. Adding a new keyword = one row
        // in the canonical grammar (and one BlockParser variant if the
        // parser function is new) — no edits to this loop.
        if let Some(consumed) = dispatch_block(line, &lines[i..], &grammar, &mut domain) {
            i += consumed;
            continue;
        }

        i += 1;
    }

    domain
}

/// i218 — block_grammar registry walker. Returns Some(consumed) when a
/// grammar entry claims the line ; None when no keyword matches and the
/// caller should advance one line.
///
/// Each BlockParser variant routes to the corresponding `parse_*`
/// function in parse_blocks.rs and pushes the result onto the right
/// Domain Vec. Aggregate parsing additionally stamps the bluebook
/// namespace as the aggregate's context (i142 — bluebooks ARE bounded
/// contexts).
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

/// Match a line against a registered keyword. The keyword is the
/// leading identifier ; we require a word-boundary after it (whitespace
/// or end of line) so `policy` doesn't claim a hypothetical
/// `policy_foo` keyword. Mirrors the existing "section ", "section\t"
/// dual check that the if-chain used.
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
            let (mut agg, consumed) = parse_aggregate(slice);
            if !domain.name.is_empty() {
                agg.context = Some(domain.name.clone());
            }
            // i560 v2 — stamp the bluebook's category onto the
            // aggregate so the merged corpus (load_combined_domain
            // wipes the per-Domain category) still resolves the FQN
            // form `Discipline::Macrophage.Run` against the directory
            // grouping. None for bluebooks that didn't declare one.
            if domain.category.is_some() {
                agg.category = domain.category.clone();
            }
            domain.aggregates.push(agg);
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
        BlockParser::Fixture => {
            // Fixtures inside a Hecks.bluebook are no-op'd Ruby-side
            // (canonical home is sibling .fixtures files). Rust still
            // walks the do/end block to consume it cleanly, matching
            // the legacy behavior.
            consume_do_block(slice)
        }
    }
}

/// Walk a `do … end` block and return the number of source lines it
/// covers (including the closing `end`). Used by Fixture dispatch as a
/// no-op consumer.
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

/// Parse a `block_grammar "Name" do … end` block declaring keyword
/// routing. Each `block "<keyword>", parser: :<parser_name>` line
/// resolves the parser_name to a BlockParser variant via
/// `BlockParser::from_name` ; unknown names are dropped (the bluebook
/// can't reach functions not linked into the binary). Empty grammars
/// are valid IR but have no effect at parse time.
pub fn parse_block_grammar(lines: &[&str]) -> (BlockGrammar, usize) {
    let first = lines[0].trim();
    let name = extract_string(first).unwrap_or_default();
    let mut bg = BlockGrammar { name, blocks: vec![] };

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

/// Parse one `block "<keyword>", parser: :<parser_name>` line into a
/// BlockGrammarEntry. Returns None when the keyword or parser is
/// missing/unparseable, or when parser_name isn't a registered variant.
fn parse_block_grammar_line(line: &str) -> Option<BlockGrammarEntry> {
    let keyword = extract_string(line)?;
    let pos = line.find("parser:")?;
    let after = line[pos + "parser:".len()..].trim();
    let parser_name = if after.starts_with(':') {
        after.trim_start_matches(':')
            .split(|c: char| c == ',' || c.is_whitespace())
            .next().unwrap_or("").to_string()
    } else if after.starts_with('"') {
        extract_string(after)?
    } else {
        after.split(|c: char| c == ',' || c.is_whitespace())
            .next().unwrap_or("").to_string()
    };
    let parser = BlockParser::from_name(&parser_name)?;
    Some(BlockGrammarEntry { keyword, parser })
}

/// Strip a leading `#!...\n` shebang line if present.
///
/// Bluebooks carrying `#!/usr/bin/env storehouse run` at the top should
/// parse identically to the same file without that line. Everything
/// after the first newline passes through untouched.
pub fn strip_shebang(source: &str) -> &str {
    if source.starts_with("#!") {
        if let Some(nl) = source.find('\n') {
            return &source[nl + 1..];
        }
        return "";
    }
    source
}

fn parse_aggregate(lines: &[&str]) -> (Aggregate, usize) {
    let first = lines[0].trim();
    let name = extract_string(first).unwrap_or_default();
    let desc = extract_second_string(first);

    let mut agg = Aggregate {
        name, description: desc,
        context: None, // populated by parse() after parse_aggregate returns
        category: None, // i560 v2 — stamped from domain.category by invoke()
        attributes: vec![],
        commands: vec![], queries: vec![], value_objects: vec![],
        entities: vec![],
        references: vec![], lifecycle: None, identified_by: None,
        invariants: vec![],
        views: vec![],
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
                if let Some(attr) = parse_attribute(line) { agg.attributes.push(attr); }
                if ends_with_do_block(line) {
                    // `attribute :status, String, default: "X" do
                    //    transition "Cmd" => "next"
                    //  end`
                    // is sugar for a lifecycle keyed on that attribute.
                    // parse_lifecycle's first-line scan reads the symbol
                    // and `default:` kwarg the same way for both forms,
                    // so we can reuse it directly.
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
                // f4 — `invariant "name" do holds_when { <predicate> } end`.
                // An aggregate-level rule checked on the resulting state
                // after every command, using the same predicate grammar as
                // a `given`. parse_invariant returns the Invariant IR + the
                // line count consumed (block-form only).
                let (inv, consumed) = parse_invariant(&lines[i..]);
                if let Some(inv) = inv { agg.invariants.push(inv); }
                i += consumed;
                continue;
            } else if line.starts_with("identified_by") {
                agg.identified_by = extract_symbol(line);
            } else if line.starts_with("view") && ends_with_do_block(line) {
                // i254 — `view "for_customer" do show :a, :b end` declares
                // a named projection. parse_view returns the View IR + the
                // line count consumed (block-form only ; no inline form).
                let (v, consumed) = parse_view(&lines[i..]);
                agg.views.push(v);
                i += consumed;
                continue;
            } else if is_shorthand_line(line) {
                absorb_shorthand(line, &mut agg);
            } else if line.starts_with("query") {
                // i101 — block-form queries flow through parse_query
                // so attribute / where / order_by / limit clauses are
                // captured as structured IR. Single-line form keeps
                // the legacy push_query path for back-compat with
                // bluebooks that only declare name + description.
                if ends_with_do_block(line) {
                    let (q, consumed) = parse_query(&lines[i..]);
                    agg.queries.push(q);
                    i += consumed;
                    continue;
                }
                push_query(line, &mut agg, &mut depth);
            } else if line.starts_with("rule ") || line.starts_with("rule\t") {
                // i259 — `rule "..." do ... end` blocks delegate to
                // consume_rule_block so a multi-statement `requires`
                // body inside can't decrement the aggregate's depth
                // (which used to silently truncate every command
                // declared after the rule from the IR). Rules aren't
                // first-class IR yet — i246 lifts them — so the
                // consumer just walks past the block.
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

    (agg, i + 1)
}

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
fn absorb_shorthand(line: &str, agg: &mut Aggregate) {
    match parse_shorthand(line) {
        ShorthandResult::Attribute(a) => agg.attributes.push(a),
        ShorthandResult::Reference(r) => agg.references.push(r),
        ShorthandResult::None => {}
    }
}

fn push_query(line: &str, agg: &mut Aggregate, depth: &mut usize) {
    let name = extract_string(line).unwrap_or_else(|| {
        line.split_whitespace().nth(1).unwrap_or("").trim_matches('"').to_string()
    });
    let desc = extract_second_string(line);
    agg.queries.push(Query {
        name,
        description: desc,
        attributes: vec![],
        wheres: vec![],
        order_by: None,
        limit: None,
    });
    if ends_with_do_block(line) { *depth += 1; }
}

// True if the line is incomplete and the next physical line is a
// continuation: either trailing comma, or unbalanced brackets/parens/braces
// (outside string literals).
#[allow(dead_code)]
fn needs_continuation(s: &str) -> bool {
    let trimmed = s.trim_end();
    if trimmed.ends_with(',') { return true; }
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
