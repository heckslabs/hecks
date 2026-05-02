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
                if let Some(h) = parse_pm_handler(line) { pm.handlers.push(h); }
                if ends_with_do_block(line) {
                    // Skip the action body — Ruby-side execution. Use
                    // indentation matching : the closing `end` of the
                    // `on ... do` block is at the same column as `on`.
                    // Tracking by `do`-counter alone breaks because Ruby
                    // action bodies use `if/else/end`, `case/end`, etc. ;
                    // those `end`s are NOT the do/end's close. Indentation
                    // is the cleanest discriminator the canonical bluebook
                    // formatting respects.
                    let on_indent = lines[i].len() - lines[i].trim_start().len();
                    while i + 1 < lines.len() {
                        i += 1;
                        let raw = lines[i];
                        let trimmed = raw.trim();
                        let indent = raw.len() - raw.trim_start().len();
                        if trimmed == "end" && indent == on_indent {
                            break;
                        }
                    }
                }
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

