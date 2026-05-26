//! story_runtime — shared step-execution helpers for Plan::Story and Plan::UseCase.
//!
//! Extracted from main.rs (core_runtime shrink) so the UseCase execution
//! surface (the runtime projection of `StoryExecuted`) can reuse the same
//! step-reading and step-arg-unpacking logic that `storehouse play` uses
//! for Storehouse::Story.
//!
//! Public API:
//!   `StoryStep`              — one executable step read back from heki
//!   `story_sorted_steps`     — extract + sort a record's `steps` array
//!   `story_args_to_tokens`   — unpack a step's JSON args bag into k=v tokens
//!
//! Example:
//!   ```ignore
//!   use storehouse::story_runtime::{story_sorted_steps, story_args_to_tokens};
//!   let steps = story_sorted_steps(&record);
//!   for step in &steps {
//!       let tokens = story_args_to_tokens(&step.args);
//!   }
//!   ```

use crate::heki;

/// One executable step of a Story or UseCase, read back from heki.
/// The `phrase` field mirrors `Storehouse::Story.Step.phrase` and
/// `Plan::UseCase.Step.phrase` — both use `phrase` as the heki key so
/// this struct works across both aggregates without modification.
pub struct StoryStep {
    pub order: i64,
    pub phrase: String,
    pub args: String,
}

/// Extract a Story or UseCase record's `steps` array, sorted ascending
/// by `order`. Tolerant of order stored as either a JSON number or a
/// numeric string (heki round-trips entity-list ints as strings).
/// Missing or malformed steps are skipped silently.
pub fn story_sorted_steps(record: &heki::Record) -> Vec<StoryStep> {
    let mut steps: Vec<StoryStep> = Vec::new();
    if let Some(serde_json::Value::Array(items)) = record.get("steps") {
        for item in items {
            let obj = match item.as_object() { Some(o) => o, None => continue };
            let phrase = match obj.get("phrase").and_then(|v| v.as_str()) {
                Some(s) if !s.is_empty() => s.to_string(),
                _ => continue,
            };
            let order = match obj.get("order") {
                Some(serde_json::Value::Number(n)) => n.as_i64().unwrap_or(0),
                Some(serde_json::Value::String(s)) => s.parse::<i64>().unwrap_or(0),
                _ => 0,
            };
            let args = obj.get("args").and_then(|v| v.as_str()).unwrap_or("{}").to_string();
            steps.push(StoryStep { order, phrase, args });
        }
    }
    steps.sort_by_key(|s| s.order);
    steps
}

/// Unpack a step's `args` (a JSON-object string like `{"text":"hi"}`)
/// into the `k=v` argv tokens storehouse_route expects. An empty object
/// or unparseable string yields no tokens. Non-string scalar values are
/// stringified so any JSON-object arg bag survives the round-trip.
pub fn story_args_to_tokens(args: &str) -> Vec<String> {
    let parsed: serde_json::Value = match serde_json::from_str(args) {
        Ok(v) => v,
        Err(_) => return Vec::new(),
    };
    let obj = match parsed.as_object() { Some(o) => o, None => return Vec::new() };
    obj.iter()
        .map(|(k, v)| {
            let val = match v {
                serde_json::Value::String(s) => s.clone(),
                other => other.to_string(),
            };
            format!("{}={}", k, val)
        })
        .collect()
}

/// Execute every use case for a story in order.
///
/// The runtime projection of `StoryExecuted` (i528 inversion). Dispatching
/// `Plan::Story.Execute` is the operator entry — the emitted `StoryExecuted`
/// event triggers this fn as its projection. It reads all Plan::UseCase records
/// whose `story_ref` field matches, sorts each use case's steps, dispatches
/// each step through `router`, then stamps each use case ran via `UseCase.Run`.
/// It does NOT call `Story.Execute` — that command is the operator's dispatch
/// trigger, not a tail stamp from the projection.
///
/// Parameters:
///   `story_ref` — the story identifier (e.g. "f15").
///   `info_dir`  — resolved HECKS_INFO path (caller owns resolution).
///   `router`    — phrase-dispatch fn so the module stays decoupled from main.
///
/// Returns 0 on success, non-zero on first failure.
pub fn storehouse_execute(story_ref: &str, info_dir: &str, router: fn(&[String]) -> i32) -> i32 {
    let heki_path = heki::path_for_lookup(info_dir, "use_case");
    let store = match heki::read(&heki_path) {
        Ok(s) => s,
        Err(e) => { eprintln!("storehouse execute: {}", e); return 3; }
    };
    // Filter use cases whose story_ref matches — stored as a string value.
    let mut matching: Vec<(String, heki::Record)> = store
        .into_iter()
        .filter(|(_, rec)| {
            match rec.get("story_ref") {
                Some(serde_json::Value::String(s)) => s == story_ref,
                _ => false,
            }
        })
        .collect();
    if matching.is_empty() {
        eprintln!("storehouse execute: no use cases for story_ref '{}' in {}", story_ref, heki_path);
        return 4;
    }
    // Stable ordering by use-case id for reproducibility.
    matching.sort_by(|a, b| a.0.cmp(&b.0));
    let total_uc = matching.len();
    let mut uc_idx = 0;
    for (uc_id, record) in &matching {
        uc_idx += 1;
        let steps = story_sorted_steps(record);
        if steps.is_empty() {
            eprintln!("[execute:{}] uc {}/{} '{}' has no steps — skipping", story_ref, uc_idx, total_uc, uc_id);
            continue;
        }
        let total_steps = steps.len();
        for (sidx, step) in steps.iter().enumerate() {
            let mut route_args: Vec<String> = vec![step.phrase.clone()];
            route_args.extend(story_args_to_tokens(&step.args));
            eprintln!("[execute:{}] uc {}/{} '{}' step {}/{} → {}", story_ref, uc_idx, total_uc, uc_id, sidx + 1, total_steps, step.phrase);
            let exit = router(&route_args);
            if exit != 0 {
                eprintln!("[execute:{}] uc '{}' step {}/{} ({}) failed (exit {}) — stopping", story_ref, uc_id, sidx + 1, total_steps, step.phrase, exit);
                return exit;
            }
        }
        // Stamp the use case ran via the pure bluebook command.
        // `UseCase.Run` must write into the plan domain's heki dir (the
        // same dir we read from above), not the global HECKS_INFO.
        // `router → run_script → infer_data_dir` re-resolves HECKS_INFO
        // from scratch; pin it to `info_dir` for this dispatch only.
        let run_args: Vec<String> = vec![
            "UseCase.Run".to_string(),
            format!("id={}", uc_id),
            format!("step_count={}", total_steps),
        ];
        let prev_hecks_info = std::env::var("HECKS_INFO").ok();
        std::env::set_var("HECKS_INFO", info_dir);
        let exit = router(&run_args);
        match &prev_hecks_info {
            Some(v) => std::env::set_var("HECKS_INFO", v),
            None    => std::env::remove_var("HECKS_INFO"),
        }
        if exit != 0 {
            eprintln!("[execute:{}] UseCase.Run for '{}' failed (exit {}) — stopping", story_ref, uc_id, exit);
            return exit;
        }
    }
    // All use cases ran. `Story.Execute` was already dispatched by the operator
    // (the caller of this projection) — do not re-dispatch it here.
    0
}
