pub fn parse_command(lines: &[&str]) -> (Command, usize) {
    let first = lines[0].trim();
    let name = extract_string(first).unwrap_or_else(|| {
        // Shorthand: bare PascalCase like `CreatePizza do`
        first.split_whitespace().next().unwrap_or("").to_string()
    });

    let mut cmd = Command {
        name, description: None, role: None, attributes: vec![],
        references: vec![], emits: None, emits_identified_by: None,
        givens: vec![], mutations: vec![],
    };

    if first.contains("{") && first.contains("}") {
        parse_inline_command(first, &mut cmd);
        return (cmd, 1);
    }

    // Bare `command "Reset"` form — no `do` block, no body. Consume
    // just the single declaration line. Without this guard the loop
    // below walks past the closing `end` of the enclosing aggregate
    // and eats subsequent siblings, since the parser thinks it's
    // looking for a matching `end` that doesn't exist.
    if !ends_with_do_block(first) {
        return (cmd, 1);
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

        if ends_with_do_block(line) {
            if depth > 1 || (!line.starts_with("attribute")
                && !line.starts_with("role")
                && !line.starts_with("given")
                && !line.starts_with("then_"))
            {
                depth += 1;
                i += 1;
                continue;
            }
        }

        if depth == 1 {
            if line.starts_with("attribute") {
                if let Some(attr) = parse_attribute(line) { cmd.attributes.push(attr); }
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
                // i250 — events have identity. `emits "X", identified_by: :foo`
                // carries the event-identity attribute name. Same word
                // aggregates use for primary keys ; reused on the emit
                // side to dedupe two reports of the same event.
                cmd.emits_identified_by = extract_kwarg_symbol(line, "identified_by");
            } else if line.starts_with("reference_to") {
                if let Some(target) = extract_word_after(line, "reference_to") {
                    // i526 : honour `, as: :name` and `, role: :name`
                    // qualifiers at the COMMAND level, the same way the
                    // aggregate-level `absorb_reference_to` does. Without
                    // this, transfer-style commands declaring two refs to
                    // the same aggregate (source + destination) collapse
                    // both names to the bare aggregate snake_case — making
                    // the IR ambiguous.
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
                    // cardinality ; cardinality + kind ride into the IR via
                    // the impl helpers added by ImplReference fixture.
                    cmd.references.push(Reference::single(name, target, None));
                }
            } else if line.starts_with("given") {
                // Two forms:
                //   given "msg"         → expression = "msg", message = "msg"
                //   given { expr }      → expression = "expr", message = None
                //   given "msg" { expr }→ expression = "expr", message = "msg"
                // Strip the block first so quoted strings INSIDE the block
                // don't get picked up as the message argument.
                let block = extract_block(line);
                let line_no_block = match line.find('{') {
                    Some(open) => &line[..open],
                    None => line,
                };
                let msg = extract_string(line_no_block);
                let expr = block.unwrap_or_else(|| msg.clone().unwrap_or_default());
                cmd.givens.push(Given { expression: expr, message: msg });
            } else if line.starts_with("then_set") {
                if let Some(m) = parse_mutation(line) { cmd.mutations.push(m); }
            } else if line.starts_with("then_toggle") {
                if let Some(field) = extract_symbol(line) {
                    cmd.mutations.push(Mutation { field, operation: MutationOp::Toggle, value: String::new() });
                }
            } else if line.starts_with("then_delete") {
                // Record-level deletion. No field, no value — the op
                // alone says "remove this aggregate after dispatch".
                cmd.mutations.push(Mutation {
                    field: String::new(),
                    operation: MutationOp::Delete,
                    value: String::new(),
                });
            }
        }
        i += 1;
    }
    (cmd, i + 1)
}

/// Extract the role/actor name from a `role …` line. Two forms accepted :
///
///   role "Customer"
///     Legacy quoted form — name is the literal string.
///
///   role Role[, as: Agent[, kind: "system"]]
///     i483 typed form — name is the bare identifier immediately after
///     `role`. The `as:` / `kind:` kwargs are accepted-and-ignored on
///     both Rust and Ruby sides until the parser-support follow-up
///     lifts them into the IR. Critically : the bareword form must
///     NOT fall back to extract_string, which would pick up the
///     quoted "system" inside a trailing `kind:` clause and silently
///     misidentify the role name.
fn parse_role_arg(line: &str) -> Option<String> {
    let after = line.trim_start_matches("role").trim_start();
    if after.starts_with('"') {
        return extract_string(after);
    }
    // Bareword form — read up to the first comma, whitespace, or
    // line end, and return the leading identifier.
    let end = after
        .find(|c: char| c == ',' || c.is_whitespace())
        .unwrap_or(after.len());
    let token = after[..end].trim();
    if token.is_empty() { None } else { Some(token.to_string()) }
}

/// Parse a `factory "X"[, produces: Y] do … end` block — a BIRTH
/// (2026-06-12 first-class-factories design). The body grammar is
/// identical to a command's (role, attributes, givens, emits,
/// then_set …), so the body is read by parse_command and lifted into
/// the Factory node. `produces:` names the aggregate this factory
/// mints ; None = the enclosing aggregate. The transitional `create`
/// keyword (#729) parses through here too until the phase-4 sweep.
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

/// Extract the bare-constant target of a `produces:` kwarg —
/// `factory "DraftStory", produces: Story do` → Some("Story").
/// Bare PascalCase ident ; trailing `do` / `,` / `{` delimiters end it.
fn extract_produces(first: &str) -> Option<String> {
    let pos = first.find("produces:")?;
    let after = first[pos + "produces:".len()..].trim_start();
    let end = after
        .find(|c: char| !(c.is_alphanumeric() || c == '_' || c == ':'))
        .unwrap_or(after.len());
    let token = after[..end].trim().trim_end_matches(':');
    if token.is_empty() { None } else { Some(token.to_string()) }
}

