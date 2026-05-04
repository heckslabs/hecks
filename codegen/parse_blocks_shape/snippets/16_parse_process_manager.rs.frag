/// Parse a `process_manager "Name" do … end` block.
///
/// Captures the static shape of the PM (name, correlates_by, starts_on,
/// ends_on, declared states, and per-event handlers with their from→to
/// transition). The action body inside `on "Event", transition: { x: :y }
/// do |event, pm| … end` is intentionally consumed-and-discarded — that
/// proc is Ruby-side execution, not part of the parity contract.
///
/// Form:
///   process_manager "SleepCycle" do
///     correlates_by :body_id
///     starts_on    "SleepStarted"
///     ends_on      "WakeFinished"
///     state "light"
///     state "rem"
///     on "PhaseElapsed", transition: { light: :light } do |event, pm|
///       { commands: ["AdvancePhase"] }
///     end
///   end
///
/// Returns the parsed ProcessManager plus the number of source lines
/// consumed (including the closing `end`).
pub fn parse_process_manager(lines: &[&str]) -> (ProcessManager, usize) {
    let first = lines[0].trim();
    let name = extract_string(first).unwrap_or_default();
    let mut pm = ProcessManager {
        name,
        correlates_by: String::new(),
        starts_on: String::new(),
        ends_on: None,
        states: vec![],
        handlers: vec![],
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
            if line.starts_with("correlates_by") {
                if let Some(sym) = extract_symbol(line) { pm.correlates_by = sym; }
            } else if line.starts_with("starts_on") {
                if let Some(s) = extract_string(line) { pm.starts_on = s; }
            } else if line.starts_with("ends_on") {
                if let Some(s) = extract_string(line) { pm.ends_on = Some(s); }
            } else if line.starts_with("state ") || line.starts_with("state\t") {
                if let Some(s) = extract_string(line) { pm.states.push(s); }
            } else if line.starts_with("on ") || line.starts_with("on\t") {
                let mut handler = parse_pm_handler(line);
                if ends_with_do_block(line) {
                    // Walk the body to its indent-matched closing `end`.
                    // Capture `dispatch "Cmd"` lines as declarative
                    // dispatches ; other body lines (Ruby-proc form,
                    // conditionals, etc.) are still consumed-and-discarded
                    // (opaque to Rust). Phase 2.b
                    // (pm-dispatch-enrichment) glues continuation lines
                    // when a `dispatch ..., with: {` hash spans multiple
                    // lines, so the parser sees one logical dispatch
                    // statement at a time.
                    let on_indent = lines[i].len() - lines[i].trim_start().len();
                    while i + 1 < lines.len() {
                        i += 1;
                        let raw = lines[i];
                        let trimmed = raw.trim();
                        let indent = raw.len() - raw.trim_start().len();
                        if trimmed == "end" && indent == on_indent {
                            break;
                        }
                        if !is_dispatch_start(trimmed) && !is_set_start(trimmed) {
                            continue;
                        }
                        // Glue continuation lines until braces +
                        // parens are balanced (with: hash + sentinel
                        // calls can wrap across multiple lines).
                        let mut joined = trimmed.to_string();
                        while !is_balanced(&joined) && i + 1 < lines.len() {
                            i += 1;
                            joined.push(' ');
                            joined.push_str(lines[i].trim());
                        }
                        if let Some(ref mut h) = handler {
                            if is_dispatch_start(&joined) {
                                if let Some(spec) = parse_dispatch_statement(&joined) {
                                    h.dispatches.push(spec);
                                }
                            } else if is_set_start(&joined) {
                                if let Some((attr, spec)) = parse_set_statement(&joined) {
                                    h.set_specs.push((attr, spec));
                                }
                            }
                        }
                    }
                }
                if let Some(h) = handler { pm.handlers.push(h); }
            } else if ends_with_do_block(line) {
                depth += 1;
            }
        } else if ends_with_do_block(line) {
            depth += 1;
        }

        i += 1;
    }
    (pm, i + 1)
}

