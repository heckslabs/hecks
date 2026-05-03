/// Parse a `cadence "Name" do … end` block declaring scheduled
/// dispatch. i218 — invoked via the block_grammar registry.
///
/// Form :
///   cadence "BodyTick" do
///     every "1s"
///     dispatch "Consciousness.ElapsePhase", name: "consciousness"
///     dispatch "Tick.MindstreamTick",       name: "tick"
///   end
pub fn parse_cadence(lines: &[&str]) -> (Cadence, usize) {
    let first = lines[0].trim();
    let name = extract_string(first).unwrap_or_default();
    let mut cad = Cadence {
        name,
        interval: String::new(),
        dispatches: vec![],
    };

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

        if depth == 1 {
            if line.starts_with("every") {
                if let Some(s) = extract_string(line) { cad.interval = s; }
            } else if line.starts_with("dispatch ")
                || line.starts_with("dispatch\t")
                || line.starts_with("dispatch\"")
            {
                if let Some(d) = parse_cadence_dispatch_line(line) {
                    cad.dispatches.push(d);
                }
            } else if ends_with_do_block(line) {
                depth += 1;
            }
        } else if ends_with_do_block(line) {
            depth += 1;
        }

        i += 1;
    }
    (cad, i + 1)
}

