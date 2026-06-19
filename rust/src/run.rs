//! Script-mode runner — `storehouse run <file.bluebook> [key=val ...]`
//!
//! Reads a .bluebook, strips its shebang, finds the companion
//! .hecksagon (sibling file with the same stem), parses both, wires
//! adapters through the runtime, and dispatches the bluebook's
//! `entrypoint` command with attrs bound from argv.
//!
//! Exit codes:
//!   0 clean
//!   1 parse failure (bluebook or hecksagon)
//!   2 guard failure (no entrypoint, gate denied)
//!   3 adapter failure (shell non-zero, timeout, etc.)
//!   4 command not found
//!
//! Shebang form:
//!   #!/usr/bin/env storehouse run
//!   Hecks.bluebook "Whatever" do
//!     entrypoint "MainCommand"
//!     ...
//!   end
//!
//! Companion hecksagon discovery:
//!   `<stem>.hecksagon` — same directory, same stem.

use crate::hecksagon_ir::Hecksagon;
use crate::ir::Domain;
use crate::runtime::adapter_registry::AdapterRegistry;
use crate::runtime::{Runtime, Value};
use crate::{hecksagon_parser, parser};

use std::collections::HashMap;
use std::path::Path;

/// Exit code shape — see module docs.
#[derive(Debug, Clone, Copy)]
pub enum ExitKind {
    Ok,
    ParseFailure,
    GuardFailure,
    AdapterFailure,
    CommandNotFound,
}

impl ExitKind {
    pub fn code(self) -> i32 {
        match self {
            ExitKind::Ok => 0,
            ExitKind::ParseFailure => 1,
            ExitKind::GuardFailure => 2,
            ExitKind::AdapterFailure => 3,
            ExitKind::CommandNotFound => 4,
        }
    }
}

/// Parse a bluebook and its companion .hecksagon (if present) and
/// return the wired runtime + adapter registry. Caller dispatches.
pub fn load_script(path: &str) -> Result<(Domain, Hecksagon), ExitKind> {
    let source = std::fs::read_to_string(path).map_err(|e| {
        eprintln!("storehouse run: cannot read {}: {}", path, e);
        ExitKind::ParseFailure
    })?;
    let domain = parser::parse(&source);
    if domain.name.is_empty() {
        eprintln!("storehouse run: {} is not a bluebook (Hecks.bluebook header missing)", path);
        return Err(ExitKind::ParseFailure);
    }
    let hex = companion_hecksagon(path);
    Ok((domain, hex))
}

/// Locate `<stem>.hecksagon` next to the given bluebook path. Returns a
/// blank Hecksagon when no companion exists — that's fine for pure-
/// memory scripts.
pub fn companion_hecksagon(bluebook_path: &str) -> Hecksagon {
    let p = Path::new(bluebook_path);
    let parent = p.parent().unwrap_or_else(|| Path::new("."));
    let stem = p.file_stem().and_then(|s| s.to_str()).unwrap_or("");
    let candidate = parent.join(format!("{}.hecksagon", stem));
    if candidate.exists() {
        match std::fs::read_to_string(&candidate) {
            Ok(src) => hecksagon_parser::parse(&src),
            Err(_) => Hecksagon::default(),
        }
    } else {
        Hecksagon::default()
    }
}

/// Full entry point: argv is `["storehouse", "run", path, ...attrs]`.
/// Returns the exit code the caller should propagate to the OS.
pub fn run_script(args: &[String]) -> i32 {
    if args.len() < 3 {
        eprintln!("Usage: storehouse run <file.bluebook> [key=val ...]");
        return ExitKind::ParseFailure.code();
    }
    let path = &args[2];
    let extra = &args[3..];

    let (domain, hex) = match load_script(path) {
        Ok(x) => x,
        Err(e) => return e.code(),
    };
    // Entrypoint resolution : explicit `entrypoint=<Aggregate.Command>`
    // override in argv wins (lets capability runners with multiple
    // phases — Restructure's Plan / Apply / RevertTo, future ones —
    // pick a phase per-invocation), otherwise the bluebook's declared
    // entrypoint, otherwise an error.
    let cli_entrypoint = extra.iter()
        .find_map(|a| a.strip_prefix("entrypoint=").map(String::from));
    let entrypoint = match (cli_entrypoint, domain.entrypoint.clone()) {
        (Some(e), _) => e,
        (None, Some(e)) => e,
        (None, None) => {
            eprintln!("storehouse run: {} declares no `entrypoint \"…\"` (pass entrypoint=<Aggregate.Command> to override)", path);
            return ExitKind::GuardFailure.code();
        }
    };

    // Attrs from argv: each `key=val` pair becomes a Value::Str. This
    // mirrors the bluebook-dispatch loop in main.rs.
    let attrs: HashMap<String, Value> = extra.iter().filter_map(|a| {
        let mut parts = a.splitn(2, '=');
        let k = parts.next()?;
        let v = parts.next()?;
        Some((k.to_string(), Value::Str(v.to_string())))
    }).collect();

    let registry = AdapterRegistry::from_hecksagon(hex.clone());
    // Resolve the per-domain world store by the bluebook category (the same
    // mapping the StoryExecuted projection uses) so a step dispatched here
    // boots against e.g. plan/.heki, not the global info dir - else a command
    // targeting plan-store data cannot find its aggregate. Falls back to
    // infer_data_dir when the bluebook declares no world store.
    let data_dir = domain.category.as_ref()
        .and_then(|cat| crate::world::attach::collect_world_heki_dirs(
            &crate::storehouse_router::conception_root()).get(cat).cloned())
        .or_else(|| infer_data_dir(path));
    // Boot WITH the companion hecksagon attached (not just used for
    // capability detection). The `:claude_tool` / `:mcp` / `:web_tool`
    // adapter-resolution arms in Runtime::dispatch scan `rt.hecksagons`
    // and early-return when it's empty — so a use-case step whose phrase
    // is a tool command (ShellTool.Bash, FileTool.Edit, …) recorded its
    // event but never fired the side-effect adapter. The tool adapter
    // declarations live in the bluebook's companion `.hecksagon`
    // (framework/tools/tools.hecksagon for the Tools.* family), which the
    // `route`→`run_script` step path already resolves alongside the
    // bluebook. Attaching it here makes the step-runner dispatch fire
    // adapters identically to the direct main.rs dispatch path.
    let mut rt = Runtime::boot_with_hecksagons(domain, data_dir, vec![hex]);
    // `:mcp` adapters (EmailTool, …) resolve through world servers walked
    // from `.world` files ; root at the conception so a step that
    // dispatches an :mcp tool command can reach its server, mirroring the
    // direct dispatch_hecksagon path's attach_world_servers call.
    crate::world::attach::attach_world_servers(
        &mut rt, &crate::storehouse_router::conception_root());
    // Sprint 14 — union top-level `adapter "Name" do ... end` bindings
    // from the same `*.world` walk so the driven_adapter_resolver can
    // pick canned (no binding) vs real (binding present) at fire time.
    crate::world::attach::attach_world_adapter_bindings(
        &mut rt, &crate::storehouse_router::conception_root());

    // Stdin-loop capability detection: when the hecksagon declares both
    // :stdin and :stdout AND the bluebook's Session aggregate exposes
    // ReadLine + RespondWith + EndSession, run the interactive loop.
    // Otherwise this is a one-shot script — dispatch the entrypoint and
    // exit.
    if is_stdin_loop_capability(&registry, &rt) {
        return crate::run_stdin_loop::run(&mut rt, &registry, &entrypoint, attrs);
    }

    // Status-report capability detection: :fs + :stdout adapters plus a
    // StatusReport aggregate with GenerateReport. The status runner
    // reads the declared .heki stores, checks the mindstream pidfile,
    // counts bluebooks, and prints a labeled multi-section report.
    if crate::run_status::is_status_report_capability(&registry, &rt) {
        return crate::run_status::run(&mut rt, &registry, &entrypoint, path, extra);
    }

    // Boot capability detection: :fs + :stdout + a BootRun aggregate
    // with BeginBoot. Walks the eight pipeline phases declared in
    // capabilities/boot/boot.bluebook, dispatching :fs / :memory /
    // :daemon / :stdout for each. Replaces the imperative
    // hecks_conception/boot_miette.sh.
    if crate::run_boot::is_boot_capability(&registry, &rt) {
        return crate::run_boot::run(&mut rt, &registry, &entrypoint, path, extra);
    }

    // Wake capability detection : :fs + WakeReview aggregate with
    // ComposeWakeReview. Walks the six pipeline phases declared in
    // runtime/wake/wake.bluebook, reading consciousness/lucid_dream/
    // dream_interpretation hekis and writing the wake-review markdown
    // to /tmp/wake_review_latest.md. Retires the prose-in-system-prompt
    // wake ritual that re-improvised the read sequence on every session.
    if crate::run_wake::is_wake_capability(&registry, &rt) {
        return crate::run_wake::run(&mut rt, &registry, &entrypoint, path, extra);
    }

    // Restructure capability detection : :fs + :stdout + Layout aggregate
    // with Apply + Move aggregate. Routes Layout.Plan / Apply / RevertTo
    // to the phase orchestrator that walks the filesystem, dispatches
    // per-Move commands, and observes the VerifyOnApplied policy chain.
    // Any other entrypoint falls through to the generic dispatcher
    // inside the runner.
    if crate::run_restructure::is_restructure_capability(&registry, &rt) {
        return crate::run_restructure::run(&mut rt, &registry, &entrypoint, path, extra);
    }

    match rt.dispatch(&entrypoint, attrs) {
        Ok(result) => {
            // Runtime projection of StoryExecuted — the operator dispatches
            // `Plan::Story.Execute` through the door; when it emits
            // `StoryExecuted` the projection runs the story's use cases.
            // The story_ref lives on event.aggregate_id (Story is identified_by
            // :ref, so aggregate_id IS the ref). No Story.Execute tail-call
            // inside the runner — that command is already done.
            #[cfg(not(target_arch = "wasm32"))]
            if let Some(ref ev) = result.event {
                // Prefer the world-declared heki dir (the plan domain's
                // .heki) over the global info dir so the projection's reads
                // find the records the plan world persists. Falls back to
                // global info_dir when no adjacent .world file is found.
                let heki_dir = || crate::storehouse_router::world_heki_dir(path)
                    .or_else(crate::storehouse_router::info_dir);
                // Runtime projection of StoryExecuted — dispatching
                // `Plan::Story.Execute` runs the story's use cases. The
                // story_ref IS event.aggregate_id (Story is identified_by
                // :ref). No Story.Execute tail-call — that command is done.
                if ev.name == "StoryExecuted" {
                    match heki_dir() {
                        Some(dir) => {
                            let exit = crate::story_runtime::storehouse_execute(
                                &ev.aggregate_id, &dir, crate::storehouse_router::route);
                            if exit != 0 { return exit; }
                        }
                        None => eprintln!("[StoryExecuted] cannot resolve heki dir — use cases not run"),
                    }
                }
                // Runtime projection of SprintExecuted — fan out over the
                // sprint's stories (Story.sprint == sprint number) and run
                // each story's use cases DIRECTLY (not by re-dispatching
                // Plan::Story.Execute, which would double-run). The sprint
                // number IS event.aggregate_id (Sprint identified_by :number).
                else if ev.name == "SprintExecuted" {
                    match heki_dir() {
                        Some(dir) => {
                            let exit = crate::story_runtime::sprint_execute(
                                &ev.aggregate_id, &dir, crate::storehouse_router::route);
                            if exit != 0 { return exit; }
                        }
                        None => eprintln!("[SprintExecuted] cannot resolve heki dir — stories not run"),
                    }
                }
            }
            ExitKind::Ok.code()
        }
        Err(crate::runtime::RuntimeError::UnknownCommand(_)) => {
            eprintln!("storehouse run: entrypoint {} not found in {}", entrypoint, path);
            ExitKind::CommandNotFound.code()
        }
        Err(e) => {
            eprintln!("storehouse run: {}", e);
            ExitKind::AdapterFailure.code()
        }
    }
}

/// True when the adapter registry + bluebook shape demand an interactive
/// REPL: stdin and stdout declared, ReadLine + RespondWith commands
/// present on some aggregate. Detection keeps the runner behaviorally
/// identical to the old adapter_terminal.rs.
pub fn is_stdin_loop_capability(registry: &AdapterRegistry, rt: &Runtime) -> bool {
    let has_stdio = registry.io("stdin").is_some() && registry.io("stdout").is_some();
    if !has_stdio { return false; }
    let mut has_read = false;
    let mut has_respond = false;
    for agg in &rt.domain.aggregates {
        for cmd in &agg.commands {
            if cmd.name == "ReadLine" { has_read = true; }
            if cmd.name == "RespondWith" { has_respond = true; }
        }
    }
    has_read && has_respond
}

/// Pick a data dir for `run_script` heki persistence — ONLY when a world
/// beside the bluebook opts into heki (`dir :default` / realm). No world ->
/// None -> the runtime boots in MEMORY (principle #1 : a bare bluebook just
/// runs ; persistence is an opt-in override, never an implicit disk fallback).
///
/// This is the reason HECKS_INFO could be removed : a non-persisting run never
/// writes disk, so there is no live-store write to redirect away. A script that
/// WANTS to persist declares a companion world ; a test or a one-shot example
/// declares none and stays entirely in memory.
fn infer_data_dir(bluebook_path: &str) -> Option<String> {
    let parent = Path::new(bluebook_path).parent()?;
    crate::heki::resolve_world_store_dir(&parent.to_string_lossy())
}
