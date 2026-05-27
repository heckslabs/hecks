//! GAP 3 (usecase-query-steps) — a use-case step phrase whose dot-tail is
//! snake_case is a QUERY ; it must run through the read-only query path
//! (not the command lexicon) and report success on a non-error read.
//!
//! Exercises storehouse_router::route — the exact fn storehouse_execute
//! passes each step to — with a query-tail phrase against an isolated
//! temp conception. A passing query (exit 0) means a read/grouping card
//! in a use case can now be asserted by execution.
//!
//! Both assertions live in ONE test: they share the process-global
//! HECKS_CONCEPTION_DIR env var, so splitting them into parallel #[test]s
//! would race. One test = one env-var lifetime.

use std::path::PathBuf;

fn temp_conception(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("hecks-query-step-{}-{}", name, std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

#[test]
fn query_tail_phrase_routes_as_query() {
    let root = temp_conception("route");
    let agg_dir = root.join("aggregates").join("note");
    std::fs::create_dir_all(&agg_dir).unwrap();
    // A Note aggregate with a command (Write) and a snake_case query
    // (ByKind, where kind: :kind).
    std::fs::write(agg_dir.join("note.bluebook"),
        "Hecks.bluebook \"Note\" do\n  category \"note\"\n  aggregate \"Note\" do\n    identified_by :id\n    attribute :id, String\n    attribute :kind, String\n    command \"Write\" do\n      attribute :id, String\n      attribute :kind, String\n      then_set :kind, to: :kind\n      emits \"NoteWritten\"\n    end\n    query \"ByKind\" do\n      where kind: :kind\n    end\n  end\nend\n").unwrap();

    let prev_conc = std::env::var("HECKS_CONCEPTION_DIR").ok();
    std::env::set_var("HECKS_CONCEPTION_DIR", root.to_string_lossy().to_string());

    // 1. A KNOWN query-tail phrase routes as a query — exit 0 on a
    //    non-error read, even with zero matching rows.
    let ok_exit = storehouse::storehouse_router::route(&[
        "Note::Note.by_kind".to_string(),
        "kind=demo".to_string(),
    ]);

    // 2. An UNKNOWN query tail must not falsely succeed.
    let miss_exit = storehouse::storehouse_router::route(&[
        "Note::Note.no_such_query".to_string(),
    ]);

    match &prev_conc {
        Some(v) => std::env::set_var("HECKS_CONCEPTION_DIR", v),
        None => std::env::remove_var("HECKS_CONCEPTION_DIR"),
    }
    let _ = std::fs::remove_dir_all(&root);

    assert_eq!(ok_exit, 0, "a query-tail step phrase should route as a query and succeed");
    assert_ne!(miss_exit, 0, "an unknown query tail must not falsely succeed");
}
