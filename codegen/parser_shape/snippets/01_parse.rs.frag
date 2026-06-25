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
            // vision strings may span several physical lines (the DSL is
            // Ruby-evaluated, so Ruby's lexer reads multi-line literals
            // natively) ; reassemble from raw lines to stay byte-equal.
            let (v, consumed) = extract_string_spanning(&lines, i);
            if let Some(v) = v {
                domain.vision = Some(v);
            }
            i += consumed;
            continue;
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

