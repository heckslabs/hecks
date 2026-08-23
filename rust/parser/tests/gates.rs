//! Integration tests — drives the actual `hecks-parse` binary as a
//! subprocess against `tests/fixtures/*`, the same "shell out and check
//! the real exit code/stderr" discipline `spec/parser_parity_spec.rb`
//! (Ruby side) uses. Stage 1's core claim (every fixture fails CLOSED
//! with a real, named diagnostic — never silently succeeds, never
//! panics, never claims coverage it doesn't have) still holds for every
//! construct this crate has NOT built real IR for yet. STAGE 2 shrinks
//! `STILL_PENDING` below the same way `spec/parser_parity_spec.rb`'s own
//! `PENDING_MEMBERS`/`spec/parser_coverage_spec.rb`'s own
//! `STAGE_1_PENDING` shrink — `command.bluebook`/`query.bluebook`/
//! `value_object.bluebook`/`policy.bluebook`/`lifecycle.bluebook` now
//! parse for REAL (see `now_implemented_fixtures_parse_for_real` below),
//! since `parse::command`/`parse::query`/`parse::value_object`/
//! `parse::policy`/`parse::lifecycle` all stopped being stubs. STAGE 4
//! adds `process_manager.bluebook` to that same list (`parse::
//! process_manager`, previously fully stubbed). ADR 0025's identity
//! slice (S1, docs/dsl-work-slices.md) closes the last two:
//! `aggregate.bluebook`/`entity.bluebook` exercised `identified_by`'s
//! bare-FIELD form, previously the one remaining `not_yet_implemented`
//! diagnostic this crate raised on purpose — `build/identity.rs::
//! resolve_identity_field` builds real IR for it now, so both fixtures
//! moved to `now_implemented_fixtures_parse_for_real` below and the
//! `still_pending_bluebook_fixtures_fail_closed_naming_their_own_construct`
//! test that pinned their failure is gone — nothing is still pending.

use std::path::PathBuf;
use std::process::{Command, Output};

fn fixture(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures")
        .join(name)
}

fn run(args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_hecks-parse"))
        .args(args)
        .output()
        .expect("failed to run hecks-parse")
}

#[test]
fn now_implemented_fixtures_parse_for_real() {
    // Stage 2 taught `parse::command`/`parse::query`/`parse::value_object`/
    // `parse::policy`/`parse::lifecycle` to build real IR; STAGE 3 adds
    // `parse::read_model` (`read_model`'s own `description`/`include`/
    // `group_by`) — all six fixtures (unlike the ones above) now succeed
    // outright: exit 0, and stdout is real, non-empty `ir.json`, not a
    // diagnostic.
    let cases: &[(&str, &str)] = &[
        ("command.bluebook", "FixtureCommand"),
        ("query.bluebook", "FixtureQuery"),
        ("value_object.bluebook", "FixtureValueObject"),
        ("policy.bluebook", "FixturePolicy"),
        ("lifecycle.bluebook", "FixtureLifecycle"),
        ("read_model.bluebook", "FixtureReadModel"),
        ("process_manager.bluebook", "FixtureProcessManager"), // STAGE 4
        // ADR 0025 identity slice (S1) — `identified_by`'s bare-field
        // form, the one remaining not-yet-implemented diagnostic.
        ("aggregate.bluebook", "FixtureAggregate"),
        ("entity.bluebook", "FixtureEntity"),
    ];

    for (file, chapter) in cases {
        let path = fixture(file);
        let output = run(&["chapter", "--chapter", chapter, path.to_str().unwrap()]);
        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);

        assert!(
            output.status.success(),
            "{file}: expected a clean parse now that its construct is built. stderr={stderr}"
        );
        assert!(
            stdout.trim_start().starts_with('{'),
            "{file}: expected real ir.json on stdout, got: {stdout}"
        );
        assert!(
            stdout.contains(&format!("\"name\": \"{chapter}\"")),
            "{file}: expected the chapter's own name in its ir.json, got: {stdout}"
        );
    }
}

#[test]
fn identity_and_relationship_exemplar_preserves_ruby_ir_shape() {
    let path = fixture("identity_relationship.bluebook");
    let output = run(&[
        "chapter",
        "--chapter",
        "IdentityRelationshipFixture",
        path.to_str().unwrap(),
    ]);
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);

    assert!(
        output.status.success(),
        "identity/relationship exemplar should parse cleanly: {stderr}"
    );

    // Named multi-field identity recursively expands TenantCode before the
    // following scalar member, preserving declaration order.
    assert!(stdout.contains(
        "\"identified_by\": [\n        \"handle.tenant.value\",\n        \"handle.name\"\n      ]"
    ), "named identity paths drifted: {stdout}");

    // Inline aggregate and entity identities synthesize deterministic value
    // object names; the entity's explicit `as:` controls its minted field.
    assert!(
        stdout.contains("\"name\": \"CustomerIdentity\""),
        "aggregate inline identity type missing: {stdout}"
    );
    assert!(
        stdout.contains("\"name\": \"PortfolioReviewIdentity\""),
        "entity inline identity type missing: {stdout}"
    );
    assert!(stdout.contains(
        "\"identified_by\": [\n            \"key.day\",\n            \"key.sequence\"\n          ]"
    ), "entity inline identity paths drifted: {stdout}");

    // Relationship word and cardinality are independent IR facts.
    assert!(
        stdout.contains("\"relationship\": \"belongs_to\""),
        "belongs_to kind missing: {stdout}"
    );
    assert!(
        stdout.contains("\"relationship\": \"has_one\""),
        "has_one kind missing: {stdout}"
    );
    assert!(
        stdout.contains("\"relationship\": \"has_many\""),
        "has_many kind missing: {stdout}"
    );
    assert!(stdout.contains(
        "\"name\": \"accounts\",\n          \"type\": \"Reference<Account>\",\n          \"list\": true"
    ), "aggregate has_many is not a reference list: {stdout}");
    assert!(stdout.contains(
        "\"name\": \"related_accounts\",\n              \"type\": \"Reference<Account>\",\n              \"list\": true"
    ), "entity has_many is not a reference list: {stdout}");
}

#[test]
fn query_arguments_are_inferred_from_local_and_resolved_hop_fields() {
    let path = fixture("query_inference.bluebook");
    let output = run(&[
        "chapter",
        "--chapter",
        "QueryInferenceFixture",
        path.to_str().unwrap(),
    ]);
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);

    assert!(
        output.status.success(),
        "query-inference exemplar should parse cleanly: {stderr}"
    );

    // A bare aggregate field retains its value-object type.
    assert!(
        stdout.contains("\"name\": \"expected_label\",\n              \"type\": \"Label\""),
        "bare-field query argument was not inferred: {stdout}"
    );

    // Dotted value-object paths resolve recursively to their scalar leaf.
    assert!(
        stdout.contains("\"name\": \"expected_value\",\n              \"type\": \"String\""),
        "dotted-field query argument was not inferred: {stdout}"
    );

    // Reference hops are resolved only after the whole aggregate graph exists.
    assert!(
        stdout.contains("\"name\": \"ancestor_label\",\n              \"type\": \"Label\""),
        "reference-hop query argument was not inferred: {stdout}"
    );

    let local_label = stdout.find("\"name\": \"expected_label\"").unwrap();
    let local_value = stdout.find("\"name\": \"expected_value\"").unwrap();
    let deferred_hop = stdout.find("\"name\": \"ancestor_label\"").unwrap();
    assert!(
        local_label < local_value && local_value < deferred_hop,
        "local inference must precede the chapter-deferred hop phase: {stdout}"
    );
}

#[test]
fn aggregate_port_operation_does_not_declare_its_receiver_as_a_fact() {
    let bluebook = fixture("port_routing.bluebook");
    let hecksagon = fixture("port_routing.hecksagon");
    let output = run(&[
        "chapter",
        "--chapter",
        "PortRoutingFixture",
        bluebook.to_str().unwrap(),
        hecksagon.to_str().unwrap(),
    ]);
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);

    assert!(
        output.status.success(),
        "owner-scoped port operation should parse without reference_to: {stderr}"
    );
    assert!(stdout.contains("\"name\": \"PaymentGateway\""));
    assert!(stdout.contains("\"name\": \"Receive\""));
    assert!(stdout.contains("\"name\": \"amount\",\n                  \"type\": \"Integer\""));
    assert!(
        !stdout.contains("\"type\": \"Reference<Order>\""),
        "receiver identity leaked into operation facts: {stdout}"
    );
}

// STAGE 8: `hecks-parse resolve --chapter <Name> <file.hecksagon>` is
// now REAL (`parse::chapter::resolve_uses_framework`, built for
// `bin/project_rust`'s own opt-in Rust orchestration path) — these two
// fixtures used to be genuine `not yet implemented` cases (resolve was
// a Stage 1 stub that always failed, regardless of input) and are now
// genuine SUCCESS cases instead, the same shift
// `now_implemented_fixtures_parse_for_real` above already documents for
// `chapter`. Also confirms the CLI contract change itself: `resolve`
// now REQUIRES `--chapter` (a deliberate departure from the plan's own
// original one-argument sketch — `main.rs::run_resolve`'s own header
// has the full reasoning), so a missing `--chapter` is a USAGE error
// (exit 2), not a parse error (exit 1).
#[test]
fn hecksagon_fixtures_resolve_for_real() {
    let path = fixture("hecksagon.hecksagon");
    let output = run(&[
        "resolve",
        "--chapter",
        "FixtureHecksagon",
        path.to_str().unwrap(),
    ]);
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);

    assert!(
        output.status.success(),
        "hecksagon.hecksagon: expected a clean resolve now that resolve is built. stderr={stderr}"
    );
    assert!(
        stdout.contains("\"domain\": \"FixtureHecksagon\""),
        "hecksagon.hecksagon: expected the chapter's own name, got: {stdout}"
    );
    assert!(stdout.contains("\"Governance\""), "hecksagon.hecksagon: expected its own uses_framework \"Governance\" to be reported, got: {stdout}");

    let path = fixture("domain_port.hecksagon");
    let output = run(&[
        "resolve",
        "--chapter",
        "FixtureDomainPort",
        path.to_str().unwrap(),
    ]);
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);

    assert!(output.status.success(), "domain_port.hecksagon: expected a clean resolve now that resolve is built. stderr={stderr}");
    assert!(
        stdout.contains("\"domain\": \"FixtureDomainPort\""),
        "domain_port.hecksagon: expected the chapter's own name, got: {stdout}"
    );
    assert!(
        !stdout.contains("Governance") && !stdout.contains("Identity"),
        "domain_port.hecksagon: declares no uses_framework at all, got: {stdout}"
    );
}

#[test]
fn resolve_without_chapter_is_a_usage_error_not_a_parse_error() {
    let path = fixture("hecksagon.hecksagon");
    let output = run(&["resolve", path.to_str().unwrap()]);
    let stderr = String::from_utf8_lossy(&output.stderr);

    assert_eq!(
        output.status.code(),
        Some(2),
        "expected exit 2 (usage error) for a missing --chapter. stderr={stderr}"
    );
    assert!(
        stderr.contains("--chapter"),
        "expected the usage message to name --chapter, got: {stderr}"
    );
}

#[test]
fn a_real_grammar_violation_is_a_hard_error_not_a_stub() {
    // A deliberately malformed file — `aggregate` is not a word `File`
    // context admits (it's `bluebook`'s own inner Aggregate context) —
    // must be refused by the WORD gate itself, distinctly worded from
    // "not yet implemented".
    let dir = std::env::temp_dir().join(format!("hecks_parse_gate_test_{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("malformed.bluebook");
    std::fs::write(&path, "aggregate \"Widget\" do\nend\n").unwrap();

    let output = run(&["chapter", "--chapter", "Whatever", path.to_str().unwrap()]);
    let stderr = String::from_utf8_lossy(&output.stderr);

    assert_eq!(output.status.code(), Some(1));
    assert!(
        !stderr.contains("not yet implemented"),
        "a genuine grammar violation must not read as a stub: {stderr}"
    );
    assert!(
        stderr.contains("is not a word"),
        "expected a word-gate diagnostic, got: {stderr}"
    );

    std::fs::remove_dir_all(&dir).ok();
}

#[test]
fn a_bare_if_is_refused_by_the_shape_gate() {
    let dir = std::env::temp_dir().join(format!("hecks_parse_shape_test_{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("bare_if.bluebook");
    std::fs::write(&path, "bluebook \"X\" do\n  if true\n  end\nend\n").unwrap();

    let output = run(&["chapter", "--chapter", "X", path.to_str().unwrap()]);
    let stderr = String::from_utf8_lossy(&output.stderr);

    assert_eq!(output.status.code(), Some(1));
    assert!(
        stderr.contains("if"),
        "expected the shape gate to name the bare 'if', got: {stderr}"
    );

    std::fs::remove_dir_all(&dir).ok();
}

#[test]
fn coverage_now_reports_the_pairs_pizzas_bluebook_actually_exercises() {
    let output = run(&["coverage"]);
    assert!(output.status.success());
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        stdout.contains("[\"aggregate\", \"Bluebook\"]"),
        "expected aggregate/Bluebook covered, got: {stdout}"
    );
    assert!(
        stdout.contains("[\"sets\", \"Command\"]"),
        "expected sets/Command covered (the canonical spelling, not 'then_set'), got: {stdout}"
    );
    assert!(
        stdout.contains("[\"where\", \"Query\"]"),
        "expected where/Query covered, got: {stdout}"
    );
    assert!(
        stdout.contains("[\"port\", \"Hecksagon\"]"),
        "expected port/Hecksagon covered, got: {stdout}"
    );
    // STAGE 3: `read_model` now has a real `parse::read_model` of its
    // own (console_settings.bluebook's own `Styles`/`Curated`). ADR 0025
    // reverts the word from `report`.
    assert!(
        stdout.contains("[\"read_model\", \"Bluebook\"]"),
        "expected read_model/Bluebook covered, got: {stdout}"
    );
    assert!(
        stdout.contains("[\"include\", \"ReadModel\"]"),
        "expected include/ReadModel covered, got: {stdout}"
    );
    assert!(
        stdout.contains("[\"group_by\", \"ReadModel\"]"),
        "expected group_by/ReadModel covered, got: {stdout}"
    );
    // STAGE 4: `entity`/`process_manager` now have real `parse_body`s of
    // their own (banking.bluebook's own `LedgerEntry`/`Settlement`, and
    // the concurrently-landed `compliance`/`interview` real corpus
    // members this stage's own work happened to fully cover too).
    assert!(
        stdout.contains("[\"identified_by\", \"Entity\"]"),
        "expected identified_by/Entity covered, got: {stdout}"
    );
    assert!(
        stdout.contains("[\"correlates_by\", \"ProcessManager\"]"),
        "expected correlates_by/ProcessManager covered, got: {stdout}"
    );
    assert!(
        stdout.contains("[\"dispatch\", \"Handler\"]"),
        "expected dispatch/Handler covered, got: {stdout}"
    );
    // STILL not covered — the bare-FIELD `identified_by` form has no
    // real corpus member exercising it yet, so `Entity`'s OWN coverage
    // stays partial (real for the six words banking.bluebook's pieces
    // actually use, not a blanket claim).
    assert!(
        !stdout.contains("[\"has_many\", \"Aggregate\"]"),
        "has_many is still not built — coverage must not overclaim it: {stdout}"
    );
}

#[test]
fn usage_errors_exit_2() {
    let output = run(&[]);
    assert_eq!(output.status.code(), Some(2));

    let output = run(&["bogus-subcommand"]);
    assert_eq!(output.status.code(), Some(2));
}
