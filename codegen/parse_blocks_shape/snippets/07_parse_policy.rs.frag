pub fn parse_policy(lines: &[&str]) -> (Policy, usize) {
    let first = lines[0].trim();
    let name = extract_string(first).unwrap_or_default();
    let mut on_event = String::new();
    let mut trigger = String::new();
    let mut target_domain = None;
    // Gap #1 of the adapters-as-bluebook arc — literal args the policy
    // passes to its triggered command. `with "key", "value"` parses to
    // (key, ValueSpec::Literal { value }). One key per line, ordered.
    // This is the minimal extension that lets a policy fire
    // `Primitive::Process.Spawn cmd="…" result_into="Cascade.RecordResult"`
    // — the data the retired :exec resolver used to inline. Only the
    // two-string literal form is parsed here ; the state-aware specs
    // (from_state/templating) are deferred to later families.
    let mut with: Vec<(String, crate::ir::ValueSpec)> = vec![];

    let mut i = 1;
    while i < lines.len() {
        let line = lines[i].trim();
        if line == "end" { break; }
        if line.starts_with("on") { on_event = extract_string(line).unwrap_or_default(); }
        if line.starts_with("trigger") { trigger = extract_string(line).unwrap_or_default(); }
        if line.starts_with("across") { target_domain = extract_string(line); }
        if line.starts_with("with") {
            if let (Some(key), Some(value)) =
                (extract_string(line), extract_second_string(line))
            {
                with.push((key, crate::ir::ValueSpec::Literal { value }));
            }
        }
        i += 1;
    }
    (Policy { name, on_event, trigger_command: trigger, target_domain, with }, i + 1)
}

