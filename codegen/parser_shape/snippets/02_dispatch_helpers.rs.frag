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

