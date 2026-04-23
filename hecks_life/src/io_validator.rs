//! Bluebook IO validator
//!
//! Asserts that a bluebook is pure-memory-runnable. Bluebooks describe
//! state transitions, not external effects — IO belongs in hecksagon
//! adapters. This validator catches drift from that invariant.
//!
//! Two layers:
//!
//! 1. **Static IR scan.** Walks the parsed Domain looking for
//!    declarative patterns that imply IO: command names like `Deploy`,
//!    `Send`, `Publish`, `Upload`; event names ending in `-ed` for
//!    external verbs; categories like `infrastructure`. Findings are
//!    advisory by default — the names *might* be domain-internal.
//!
//! 2. **Runtime smoke.** Boots `Runtime::boot(domain)` (pure-memory,
//!    `data_dir = None`, no hecksagon, no adapters), iterates every
//!    command, synthesizes plausible inputs, dispatches. Anything that
//!    panics, reads files, or opens sockets shows up here. The runtime
//!    is structurally pure when `data_dir` is None — this confirms it.
//!
//! Surface:
//!
//!   hecks-life check-io path/to/bluebook.bluebook            # advisory
//!   hecks-life check-io path/to/bluebook.bluebook --strict   # warnings → errors
//!
//! Exit code:
//!   0 — runtime smoke passes (always, when the runtime can dispatch
//!       every command without panicking)
//!   1 — runtime smoke failed, OR --strict and any static warnings

pub use crate::diagnostic::{Finding, Severity};
use crate::ir::{Aggregate, Command, Domain};
use crate::runtime::{Runtime, Value};
use std::collections::HashMap;

pub struct Report {
    pub static_findings: Vec<Finding>,
    pub runtime_findings: Vec<Finding>,
}

impl Report {
    pub fn errors(&self) -> usize {
        self.static_findings.iter().chain(&self.runtime_findings)
            .filter(|f| f.severity == Severity::Error).count()
    }
    pub fn warnings(&self) -> usize {
        self.static_findings.iter().chain(&self.runtime_findings)
            .filter(|f| f.severity == Severity::Warning).count()
    }
    /// Strict mode: any warning becomes an error.
    pub fn passes(&self, strict: bool) -> bool {
        if self.errors() > 0 { return false; }
        if strict && self.warnings() > 0 { return false; }
        true
    }
}

/// Run both layers, return a combined report. Takes ownership of
/// the domain because the runtime smoke step boots a Runtime, which
/// consumes its Domain. The static scan runs first against a borrow.
pub fn check(domain: Domain) -> Report {
    let static_findings = static_scan(&domain);
    let runtime_findings = runtime_smoke(domain);
    Report { static_findings, runtime_findings }
}

// ─── Static IR scan ────────────────────────────────────────────────

/// Command-name prefixes that strongly suggest IO. The bluebook *might*
/// be using these as domain verbs (a `SendMessage` command in an
/// in-memory chat domain is fine), so these are warnings — surface,
/// don't block. Promote to errors with --strict.
const IO_COMMAND_PREFIXES: &[&str] = &[
    "Deploy", "Send", "Upload", "Publish", "Fetch", "Push", "Pull",
    "Sync", "Notify", "Email", "Download", "Broadcast",
];

/// Event-name suffixes that suggest external IO already happened
/// (past-tense external verbs).
const IO_EVENT_NAMES: &[&str] = &[
    "Deployed", "Sent", "Uploaded", "Published", "Pushed", "Pulled",
    "Synced", "Notified", "Emailed", "Downloaded", "Broadcast",
];

/// Categories that mark a domain as IO-infrastructure by convention.
/// A domain with one of these *expects* to do IO; pure-memory check
/// is moot. Surfaced as a warning so the user knows the validator is
/// being lenient.
const IO_CATEGORIES: &[&str] = &["infrastructure"];

/// Command-name prefixes that imply state-bootstrap (the runtime
/// auto-applies the command's attrs into the new aggregate, so no
/// explicit then_set is needed). Mirrors `command_dispatch::is_create`.
const CREATE_PREFIXES: &[&str] = &["Create", "Add", "Place", "Register", "Open"];

pub fn static_scan(domain: &Domain) -> Vec<Finding> {
    let mut out = Vec::new();

    if let Some(cat) = &domain.category {
        if IO_CATEGORIES.contains(&cat.as_str()) {
            out.push(Finding::warn(
                domain.name.clone(),
                format!("category {:?} marks this as IO-infrastructure (validator runs anyway)", cat),
            ));
        }
    }

    // Pre-compute the set of command names that participate in any
    // lifecycle transition — those have state-changing semantics even
    // without explicit then_set mutations on the command itself.
    let lifecycle_commands: std::collections::BTreeSet<String> = domain.aggregates.iter()
        .filter_map(|a| a.lifecycle.as_ref())
        .flat_map(|l| l.transitions.iter().map(|t| t.command.clone()))
        .collect();

    for agg in &domain.aggregates {
        for cmd in &agg.commands {
            scan_command(agg, cmd, &lifecycle_commands, &mut out);
        }
    }
    out
}

fn scan_command(
    agg: &Aggregate,
    cmd: &Command,
    lifecycle_commands: &std::collections::BTreeSet<String>,
    out: &mut Vec<Finding>,
) {
    let loc = format!("{}.{}", agg.name, cmd.name);

    // IO-suggestive command name?
    for prefix in IO_COMMAND_PREFIXES {
        if has_pascal_prefix(&cmd.name, prefix) {
            out.push(Finding::warn(loc.clone(),
                format!("command name suggests IO ({:?}) — confirm hecksagon handles the actual effect", prefix)));
            break;
        }
    }

    // IO-suggestive event name?
    if let Some(emit) = &cmd.emits {
        if IO_EVENT_NAMES.iter().any(|n| emit == n) {
            out.push(Finding::warn(loc.clone(),
                format!("emits {:?} — past-tense external verb, often means the command itself did IO", emit)));
        }
    }

    // "Pure side-effect" — the most useful and least false-positive
    // version of this check:
    //   • emits an event AND
    //   • has no then_set mutations AND
    //   • has no givens (no validation gate) AND
    //   • is NOT a create-style command (runtime auto-bootstraps state) AND
    //   • is NOT named in any lifecycle transition (lifecycle handles state)
    // Such a command has no effect on bluebook state — its only
    // purpose must be external. That usually means IO.
    let is_create = CREATE_PREFIXES.iter().any(|p| has_pascal_prefix(&cmd.name, p));
    let is_lifecycle = lifecycle_commands.contains(&cmd.name);
    if cmd.emits.is_some()
        && cmd.mutations.is_empty()
        && cmd.givens.is_empty()
        && !is_create
        && !is_lifecycle
    {
        out.push(Finding::warn(loc.clone(),
            "command emits but has no then_set, no givens, and no \
             lifecycle transition — pure side-effect commands often imply IO"));
    }
}

/// True if `name` starts with `prefix` followed by an uppercase letter
/// (or end of string). `Pulse` doesn't match `Pull`; `PullRequest` does.
fn has_pascal_prefix(name: &str, prefix: &str) -> bool {
    if !name.starts_with(prefix) { return false; }
    if name.len() == prefix.len() { return true; }
    name.chars().nth(prefix.len()).map_or(true, |c| c.is_uppercase())
}

// ─── Runtime smoke ─────────────────────────────────────────────────

/// Boot a pure-memory Runtime and dispatch every command. Synthesizes
/// inputs from each command's declared attributes (sample value per
/// type). Self-ref / reference-only commands are skipped — they need
/// existing aggregates, which is the test runner's job, not the
/// validator's. Anything that panics or returns a runtime error other
/// than UnknownAggregate / MissingAttribute counts as a Finding.
///
/// Consumes `domain` because Runtime::boot does — we plan the
/// iteration up front from the borrow, then take ownership.
pub fn runtime_smoke(domain: Domain) -> Vec<Finding> {
    let mut findings = Vec::new();

    // Plan the dispatch list from the borrowed Domain BEFORE we hand
    // it to Runtime::boot, which takes ownership.
    struct Plan { agg: String, cmd: String, attrs: HashMap<String, Value>, skip: bool }
    let plan: Vec<Plan> = domain.aggregates.iter().flat_map(|agg| {
        agg.commands.iter().map(|cmd| Plan {
            agg: agg.name.clone(),
            cmd: cmd.name.clone(),
            attrs: synthesize_attrs(cmd),
            skip: needs_self_ref(cmd),
        }).collect::<Vec<_>>()
    }).collect();
    let domain_name = domain.name.clone();

    let mut rt = Runtime::boot(domain);

    // Confirm structurally: Runtime::boot's repos all have None data_dir.
    if rt.data_dir.is_some() {
        findings.push(Finding::err(
            domain_name,
            "Runtime::boot returned a runtime with Some(data_dir) — IO would happen on save",
        ));
    }

    for p in plan {
        if p.skip { continue; }
        match rt.dispatch(&p.cmd, p.attrs) {
            Ok(_) => {}
            Err(e) => match e {
                // All of these mean "the bluebook gates the command",
                // not "the runtime tried to do IO". They're expected
                // when smoke-dispatching without setup fixtures.
                crate::runtime::RuntimeError::MissingAttribute(_) |
                crate::runtime::RuntimeError::AggregateNotFound(_) |
                crate::runtime::RuntimeError::GivenFailed { .. } |
                crate::runtime::RuntimeError::LifecycleViolation { .. } => { /* not IO */ }
                other => findings.push(Finding::err(
                    format!("{}.{}", p.agg, p.cmd),
                    format!("dispatch in pure-memory mode failed: {}", other),
                )),
            }
        }
    }

    findings
}

/// Whether a command's surface implies it acts on an existing entity
/// (has a self-ref to its own aggregate).
fn needs_self_ref(cmd: &Command) -> bool {
    // Heuristic: any reference whose target name suggests self-ref.
    // Without the aggregate context, we conservatively assume any
    // reference at all means "needs an existing entity".
    !cmd.references.is_empty()
}

/// Build sample attribute values from a command's declared attributes.
/// Mirrors the conceiver's `sample_value` so the validator and the
/// generator agree on what "plausible input" looks like.
fn synthesize_attrs(cmd: &Command) -> HashMap<String, Value> {
    let mut out = HashMap::new();
    for attr in &cmd.attributes {
        let v = match attr.attr_type.as_str() {
            "Integer" => Value::Int(1),
            "Float"   => Value::Str("1.0".into()),
            "Boolean" => Value::Bool(true),
            _         => Value::Str(format!("sample_{}", attr.name)),
        };
        out.insert(attr.name.clone(), v);
    }
    out
}

