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
    // deciderate Layer 0b — the grown policy : data guard, fan-out, extra reactions.
    let mut wheres: Vec<crate::ir::WhereClause> = vec![];
    let mut for_each: Option<crate::ir::ForEachSpec> = None;
    let mut extra_dispatches: Vec<crate::ir::DispatchSpec> = vec![];

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
        // 0b guard — `where field: value` reuses the query WhereClause grammar.
        if line.starts_with("where") {
            for w in parse_where_line(line, &[]) { wheres.push(w); }
        }
        // 0b fan-out — standalone `for_each: { from: "Agg.query" }` sweeps the
        // primary trigger (reuses the i221-A clause parser).
        if line.starts_with("for_each") {
            if let Some(fe) = parse_for_each_clause(line) { for_each = Some(fe); }
        }
        // 0b multi-reaction — each `dispatch "Cmd", with: {..}, for_each: {..}`
        // adds a reaction beyond the primary trigger.
        if is_dispatch_start(line) {
            if let Some(ds) = parse_dispatch_statement(line) { extra_dispatches.push(ds); }
        }
        i += 1;
    }
    (Policy { name, on_event, trigger_command: trigger, target_domain, with, wheres, for_each, extra_dispatches }, i + 1)
}

