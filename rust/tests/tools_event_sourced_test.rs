//! TOOL INVOCATIONS ARE DURABLY RECORDED — against the REAL conception corpus.
//!
//! Shell execution is the highest-consequence act the storehouse door carries,
//! and until now it was the least recorded thing in the system : `ShellTool` is
//! memory-backed and was not event_sourced, so a successful shell command left no
//! durable trace at all — while a DENIED one persisted as a Governance::Violation.
//! The same asymmetry 75dad37e8 closed for domain events, one layer down.
//!
//! It was not always so. ShellTool wrote ~271K of heki until 2026-06-14, because
//! `adapter :memory` had been declared for tools since the beginning but was
//! INERT — it fell through to the implicit heki default. When i728 made :memory
//! actually select Backend::Memory, the declaration finally took effect and the
//! audit trail stopped. Nothing noticed for five weeks.
//!
//! Current-state stays in Memory, which is right — a tool call is an EVENT, not an
//! entity : no lifecycle, nothing to update, and "the current state of
//! ShellTool#inv_abc" is meaningless. What must be durable is that the act
//! HAPPENED. So the binding is `event_sourced`, not `persisted_by("Heki")`.
//!
//! Booted against the REAL corpus (not a fixture) because the thing under test IS
//! the real declaration in tools.hecksagon. Data is redirected to a temp dir so
//! the test never writes to the live store.

use std::collections::HashMap;
use std::path::PathBuf;
use storehouse::runtime::{AggregateState, Runtime, Value};
use storehouse::{corpus_loader, embed};

fn conception() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..").join("hecks_conception")
}

fn boot_conception(data_name: &str) -> (Runtime, PathBuf) {
    let agg_dir = conception().join("aggregates");
    let agg_dir_s = agg_dir.to_str().unwrap();
    let data = std::env::temp_dir().join(data_name);
    let _ = std::fs::remove_dir_all(&data);
    std::fs::create_dir_all(&data).unwrap();
    let domain = corpus_loader::load_combined_domain(agg_dir_s);
    let hecksagons = embed::load_hecksagons(agg_dir_s);
    let rt = Runtime::boot_with_framework_dir(
        domain,
        Some(data.to_string_lossy().into_owned()),
        hecksagons,
        &agg_dir,
    );
    (rt, data)
}

fn event_name(e: &AggregateState) -> String {
    match e.get("event_name") {
        Value::Map(m) => m.get("value").map(|v| v.to_string()).unwrap_or_default(),
        Value::Str(s) => s.clone(),
        _ => String::new(),
    }
}

#[test]
fn a_shell_invocation_is_recorded_in_the_log() {
    let (mut rt, data) = boot_conception("tools_es_proof");

    let mut attrs = HashMap::new();
    attrs.insert("id".to_string(), Value::Str("es-audit-1".to_string()));
    attrs.insert("shell_command".to_string(), Value::Str("echo durable".to_string()));
    attrs.insert("description".to_string(), Value::Str("audit proof".to_string()));
    let _ = rt.dispatch("Tools::ShellTool.Bash", attrs);

    let events = rt.all_qualified(Some("EventSourcing"), "Event");
    let shell_rows: Vec<&&AggregateState> = events
        .iter()
        .filter(|e| e.get("aggregate_name").to_string() == "ShellTool")
        .collect();

    assert!(
        !shell_rows.is_empty(),
        "a shell invocation must reach the Log — it is the most consequential act the door carries",
    );

    // The first-class EVENT row : the act itself, not merely the field deltas.
    assert!(
        shell_rows.iter().any(|e| event_name(e) == "BashRan"),
        "the Log must carry the emitted BashRan event, not only the state deltas",
    );

    // GOVERNANCE : the record answers WHO and UNDER WHAT, which is the entire
    // reason to log a shell command rather than merely run it.
    let row = shell_rows
        .iter()
        .find(|e| event_name(e) == "BashRan")
        .expect("the BashRan row");
    assert!(
        !matches!(row.get("actor"), Value::Str(s) if s.is_empty()),
        "the invocation must record an actor",
    );
    assert!(
        !matches!(row.get("entry_hash"), Value::Str(s) if s.is_empty()),
        "the invocation must be on the tamper-evident chain",
    );

    // And the command itself is recoverable from the record — an audit trail that
    // does not say WHAT was run is not an audit trail.
    let all = format!("{:?}", shell_rows);
    assert!(all.contains("echo durable"), "the Log must carry the command that was run");

    let _ = std::fs::remove_dir_all(&data);
}

/// The FileTool half : the ACT is recorded, the BYTES are not.
///
/// `content` / `old_string` / `new_string` are declared `logged: false`. They are
/// arguments to a filesystem write, not aggregate state — and the fold never
/// re-executes a command, so a payload in the Log could never be USED on replay.
/// It would be forensic weight growing with every file written, in a Log that is
/// the source of truth for the DOMAIN and not a backup of the external world.
///
/// What must survive is the audit question: WHICH file, by WHOM, under what
/// verdict. This asserts both halves — the act present, the bytes absent — because
/// either one alone would be satisfied by a broken implementation.
#[test]
fn a_file_write_records_the_act_but_not_the_bytes() {
    let (mut rt, data) = boot_conception("tools_es_filetool");

    let secret = "SENTINEL-CONTENT-should-not-reach-the-log";
    let mut attrs = HashMap::new();
    attrs.insert("id".to_string(), Value::Str("es-file-1".to_string()));
    attrs.insert("file_path".to_string(), Value::Str("/tmp/es-file-proof.txt".to_string()));
    attrs.insert("content".to_string(), Value::Str(secret.to_string()));
    attrs.insert("description".to_string(), Value::Str("filetool proof".to_string()));
    let _ = rt.dispatch("Tools::FileTool.Update", attrs);

    let events = rt.all_qualified(Some("EventSourcing"), "Event");
    let file_rows: Vec<&&AggregateState> = events
        .iter()
        .filter(|e| e.get("aggregate_name").to_string() == "FileTool")
        .collect();
    assert!(!file_rows.is_empty(), "a file write must reach the Log");

    let rendered = format!("{file_rows:?}");
    // THE ACT — which file was written is the audit fact, and it must be there.
    assert!(
        rendered.contains("es-file-proof.txt"),
        "the Log must record WHICH file was written — got {rendered}",
    );
    // THE BYTES — withheld. If this ever fails, the Log has quietly become a
    // backup of the filesystem and grows with every byte the system writes.
    assert!(
        !rendered.contains(secret),
        "the file's CONTENT must be withheld from the Log (logged: false)",
    );

    let _ = std::fs::remove_dir_all(&data);
}

#[test]
fn completeness_holds_for_tool_dispatches() {
    // The invariant from the completeness slice, applied to the aggregate that
    // most needs it : every emitted tool event reaches the Log, none swallowed.
    let (mut rt, data) = boot_conception("tools_es_complete");
    for i in 0..3 {
        let mut attrs = HashMap::new();
        attrs.insert("id".to_string(), Value::Str(format!("es-audit-{i}")));
        attrs.insert("shell_command".to_string(), Value::Str("echo hi".to_string()));
        attrs.insert("description".to_string(), Value::Str("completeness".to_string()));
        let _ = rt.dispatch("Tools::ShellTool.Bash", attrs);
    }
    assert_eq!(
        rt.missing_event_rows(),
        0,
        "no tool invocation may be swallowed — owed {} vs written {}",
        rt.event_rows_owed,
        rt.event_rows_written,
    );
    let _ = std::fs::remove_dir_all(&data);
}
