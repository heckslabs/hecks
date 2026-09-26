// Structured logging for the host: one JSON object per line on stdout.
//
// On Fargate the task definition's `awslogs` driver ships whatever a
// container writes to stdout/stderr to CloudWatch Logs, so this module
// needs no AWS client and no configuration — printing a line is the
// whole integration. One JSON object per line (not free text) is what
// lets CloudWatch Logs Insights filter on fields, e.g.
// `filter msg = "command" and accepted = 0`. CloudWatch stamps each
// event on ingestion, so lines carry no timestamp of their own.
//
// Callers must never put secrets, cookies, query strings or command
// facts into `fields` — log identifiers (verb, role, path, status), not
// payloads.

use serde_json::{json, Map, Value};
use std::io::Write;

/// Logs an ordinary event.
pub fn info(msg: &str, fields: Value) {
    emit("info", msg, fields);
}

/// Logs a failure worth an operator's attention.
pub fn error(msg: &str, fields: Value) {
    emit("error", msg, fields);
}

/// A boot phase in flight. Logs `boot_phase` with `event: "start"` when it
/// begins and `event: "end"` with `elapsed_ms` when it finishes, so a hang shows
/// as a start line with no end line after it. A phase that fails simply never
/// logs its end (the error itself is what the process reports).
///
/// `fields` are identifiers only (an aggregate's storage name, an era number),
/// never data, and are repeated on both lines.
pub struct Phase {
    name: &'static str,
    fields: Value,
    started: std::time::Instant,
}

/// Starts a boot phase with no extra fields.
pub fn phase(name: &'static str) -> Phase {
    phase_with(name, json!({}))
}

/// Starts a boot phase and logs its `start` line.
pub fn phase_with(name: &'static str, fields: Value) -> Phase {
    emit("info", "boot_phase", phase_fields(name, "start", &fields, None));
    Phase { name, fields, started: std::time::Instant::now() }
}

impl Phase {
    /// Logs the `end` line and returns the elapsed milliseconds.
    pub fn end(self) -> u64 {
        self.end_with(json!({}))
    }

    /// Logs the `end` line with extra fields describing the outcome.
    pub fn end_with(self, outcome: Value) -> u64 {
        let elapsed_ms = self.started.elapsed().as_millis() as u64;
        let mut fields = self.fields.clone();
        if let (Value::Object(base), Value::Object(extra)) = (&mut fields, outcome) {
            base.extend(extra);
        }
        emit("info", "boot_phase", phase_fields(self.name, "end", &fields, Some(elapsed_ms)));
        elapsed_ms
    }
}

/// The fields of one phase line: `phase`, `event`, `elapsed_ms` on an end line,
/// then the phase's own identifiers.
fn phase_fields(name: &str, event: &str, fields: &Value, elapsed_ms: Option<u64>) -> Value {
    let mut object = Map::new();
    object.insert("phase".to_string(), json!(name));
    object.insert("event".to_string(), json!(event));
    if let Some(ms) = elapsed_ms {
        object.insert("elapsed_ms".to_string(), json!(ms));
    }
    if let Value::Object(fields) = fields {
        for (key, value) in fields {
            object.entry(key.clone()).or_insert(value.clone());
        }
    }
    Value::Object(object)
}

fn emit(level: &str, msg: &str, fields: Value) {
    let line = render(level, msg, fields);
    // A closed stdout must never take a request down with it.
    let _ = writeln!(std::io::stdout().lock(), "{line}");
}

/// The line as text — `level` and `msg` first, then `fields` (an object;
/// anything else is ignored).
fn render(level: &str, msg: &str, fields: Value) -> String {
    let mut object = Map::new();
    object.insert("level".to_string(), json!(level));
    object.insert("msg".to_string(), json!(msg));
    if let Value::Object(fields) = fields {
        for (key, value) in fields {
            object.entry(key).or_insert(value);
        }
    }
    Value::Object(object).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renders_one_json_object_on_a_single_line() {
        let line = render("info", "request", json!({"method": "GET", "status": 200}));
        assert!(!line.contains('\n'));
        let parsed: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(parsed["level"], "info");
        assert_eq!(parsed["msg"], "request");
        assert_eq!(parsed["method"], "GET");
        assert_eq!(parsed["status"], 200);
    }

    #[test]
    fn a_field_cannot_overwrite_level_or_msg() {
        let line = render("error", "boom", json!({"level": "info", "msg": "fine"}));
        let parsed: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(parsed["level"], "error");
        assert_eq!(parsed["msg"], "boom");
    }

    #[test]
    fn a_phase_line_names_the_phase_and_an_end_line_carries_elapsed_ms() {
        let start = render("info", "boot_phase", phase_fields("audit_aggregate", "start", &json!({"aggregate": "registration"}), None));
        let parsed: Value = serde_json::from_str(&start).unwrap();
        assert_eq!(parsed["msg"], "boot_phase");
        assert_eq!((parsed["phase"].as_str(), parsed["event"].as_str()), (Some("audit_aggregate"), Some("start")));
        assert_eq!(parsed["aggregate"], "registration");
        assert!(parsed.get("elapsed_ms").is_none(), "a start line has no duration yet");

        let end = render("info", "boot_phase", phase_fields("audit_aggregate", "end", &json!({"aggregate": "registration"}), Some(42)));
        let parsed: Value = serde_json::from_str(&end).unwrap();
        assert_eq!((parsed["event"].as_str(), parsed["elapsed_ms"].as_u64()), (Some("end"), Some(42)));
    }

    #[test]
    fn a_phase_field_cannot_overwrite_the_phase_or_event() {
        let fields = phase_fields("connect", "start", &json!({"phase": "other", "event": "end", "era": 7}), None);
        assert_eq!((fields["phase"].as_str(), fields["event"].as_str(), fields["era"].as_u64()), (Some("connect"), Some("start"), Some(7)));
    }

    #[test]
    fn ending_a_phase_reports_elapsed_time_and_merges_the_outcome() {
        let phase = phase_with("mint_era", json!({"era": 7}));
        std::thread::sleep(std::time::Duration::from_millis(15));
        let elapsed = phase.end_with(json!({"aggregates": 5}));
        assert!(elapsed >= 15, "{elapsed}");
    }

    #[test]
    fn newlines_inside_a_value_stay_escaped() {
        let line = render("error", "boom", json!({"error": "a\nb"}));
        assert!(!line.contains('\n'));
    }
}
