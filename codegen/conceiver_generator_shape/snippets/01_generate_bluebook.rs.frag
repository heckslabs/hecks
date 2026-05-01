/// Generate a scaffold bluebook from an archetype's structure.
/// Outputs the right shape with placeholder names — you fill in the vocabulary.
pub fn generate_bluebook(name: &str, vision: &str, archetype: &Domain) -> String {
    let snake = to_snake(name);
    let mut out = Vec::new();
    out.push(format!("Hecks.bluebook \"{}\", version: \"{}\" do", name, VERSION));
    out.push(format!("  vision \"{}\"", vision));
    if let Some(ref cat) = archetype.category {
        out.push(format!("  category \"{}\"", cat));
    }
    out.push(String::new());

    for (i, agg) in archetype.aggregates.iter().enumerate() {
        emit_scaffold(&mut out, i + 1, agg);
        out.push(String::new());
    }

    let n_policies = archetype.policies.len();
    for i in 0..n_policies {
        out.push(format!("  # policy {} — TODO: wire events to commands", i + 1));
    }
    if n_policies > 0 { out.push(String::new()); }

    if out.last().map(|l| l.is_empty()).unwrap_or(false) {
        out.pop();
    }
    out.push("end".into());
    out.join("\n")
}

