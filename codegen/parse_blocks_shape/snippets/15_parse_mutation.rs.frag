pub fn parse_mutation(line: &str) -> Option<Mutation> {
    let field = extract_symbol(line)?;
    let (op, value) = if line.contains("append:") {
        (MutationOp::Append, extract_after(line, "append:")?)
    } else if line.contains("remove:") {
        (MutationOp::Remove, extract_after(line, "remove:")?)
    } else if line.contains("increment:") {
        (MutationOp::Increment, extract_after(line, "increment:")?)
    } else if line.contains("decrement:") {
        (MutationOp::Decrement, extract_after(line, "decrement:")?)
    } else if line.contains("multiply:") {
        // i106 — multiplicative scaling. Value is the f64 factor.
        (MutationOp::Multiply, extract_after(line, "multiply:")?)
    } else if line.contains("clamp:") {
        // i106 — bound a field to [min, max]. Value is the list literal.
        (MutationOp::Clamp, extract_after(line, "clamp:")?)
    } else if line.contains("decay:") {
        // i106 — exponential decay. Value is the rate (0.05 → ×0.95).
        (MutationOp::Decay, extract_after(line, "decay:")?)
    } else if line.contains("to:") {
        (MutationOp::Set, extract_after(line, "to:")?)
    } else if line.contains("from:") {
        // i106 — `then_set :field, from: :param` reads the named command
        // param at dispatch time. We carry the source symbol form
        // (`:param`) so the canonical IR matches Ruby's then_set
        // path : Ruby's mutation_value formats Symbol → ":param", and
        // extract_after returns the raw `:param` token here. Both
        // sides emit `value: ":param"` after canonical normalization.
        (MutationOp::Set, extract_after(line, "from:")?)
    } else {
        // Positional form: `then_set :field, <value>` — value is the
        // token after the field's symbol, separated by a comma.
        let sym_start = line.find(':')? + 1;
        let after_field = &line[sym_start + field.len()..];
        let comma = after_field.find(',')?;
        let raw = after_field[comma + 1..].trim();
        let value = if raw.starts_with('"') {
            // Quoted string — strip surrounding quotes.
            let end = raw[1..].find('"').map(|i| i + 1)?;
            raw[1..end].to_string()
        } else {
            // Bare token — number, true, false, or :symbol.
            raw.split(|c: char| c == ',' || c.is_whitespace())
                .next().unwrap_or("").to_string()
        };
        if value.is_empty() { return None; }
        (MutationOp::Set, value)
    };
    Some(Mutation { field, operation: op, value })
}

