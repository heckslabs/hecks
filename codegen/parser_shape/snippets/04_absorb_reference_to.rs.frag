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

