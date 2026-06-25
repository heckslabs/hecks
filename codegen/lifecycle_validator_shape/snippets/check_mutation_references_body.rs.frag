    for cmd in &agg.commands {
        for m in &cmd.mutations {
            // Only Set mutations have a value to resolve. Append /
            // Increment / Decrement / Toggle work differently.
            if !matches!(m.operation, MutationOp::Set) { continue; }
            let raw = m.value.trim();

            // Clock anti-patterns — flag specifically with a hint.
            if raw == ":now" || raw == "now" {
                out.push(Finding::err(
                    format!("{}.{}", agg.name, cmd.name),
                    format!(
                        "then_set :{} reaches the system clock via :now — \
                         the domain shouldn't grab time, it's infrastructure. \
                         Inject it: `attribute :{}, String` on the command + \
                         `then_set :{}, to: :{}` so the caller (test, app, \
                         hecksagon adapter) provides the timestamp.",
                        m.field, m.field, m.field, m.field,
                    ),
                ));
                continue;
            }
            if raw.starts_with("seconds_since(") {
                out.push(Finding::err(
                    format!("{}.{}", agg.name, cmd.name),
                    format!(
                        "then_set :{} uses seconds_since(...) — the runtime \
                         synthesizes elapsed time from the system clock. \
                         Inject the elapsed value as a command attribute \
                         instead, computed by the caller (Clock port).",
                        m.field,
                    ),
                ));
                continue;
            }

            let Some(sym) = raw.strip_prefix(':') else { continue };
            // Allow further wrapping (e.g. trailing whitespace before
            // a brace). Only flag bare-identifier symbols.
            let name: String = sym.chars()
                .take_while(|c| c.is_alphanumeric() || *c == '_')
                .collect();
            if name.is_empty() { continue; }

            let in_attrs = cmd.attributes.iter().any(|a| a.name == name);
            let in_refs  = cmd.references.iter().any(|r| r.name == name);
            if !in_attrs && !in_refs {
                out.push(Finding::err(
                    format!("{}.{}", agg.name, cmd.name),
                    format!(
                        "then_set :{} references :{} but the command has \
                         neither an attribute nor a reference named {:?} — \
                         the field will stay null at runtime",
                        m.field, name, name,
                    ),
                ));
            }
        }
    }
