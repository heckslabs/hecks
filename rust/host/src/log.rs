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
    fn newlines_inside_a_value_stay_escaped() {
        let line = render("error", "boom", json!({"error": "a\nb"}));
        assert!(!line.contains('\n'));
    }
}
