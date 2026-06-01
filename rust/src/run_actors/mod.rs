//! `storehouse actors` — debug command for the actor-model surface
//! (sprint 14 — story `storehouse-actors-debug-command`).
//!
//! Three subcommands ; one mechanism :
//!   storehouse actors list             — every active mailbox, table or JSON
//!   storehouse actors show <type> <id> — detail on one mailbox
//!   storehouse actors poisoned         — filter to poisoned mailboxes only
//!
//! All three accept `--json` for tooling consumers ; the human form
//! prints a fixed-width table. The data axes are queue_depth, status
//! (live/poisoned), events_processed, dropped_duplicates, last_error.
//!
//! Today's surface : the live runtime does not yet hold a global
//! `MailboxRegistry` (sprint 14 cards #03–#08 build the registry ; the
//! event-bus integration is a follow-up sprint per `runtime/actor/mod.rs`
//! header). So `list` against an idle runtime prints an empty table.
//! The `--fixture` flag (used by the behavior test and by humans
//! exploring the shape) spawns three mailboxes — one idle, one with
//! envelopes still queued, one poisoned — so the rendering contract is
//! visible end-to-end before the bus wires it through.
//!
//! When the runtime starts holding a process-wide registry (a separate
//! sprint card), `gather_registry` swaps from the fixture path to the
//! real registry without touching the rendering code.

use crate::runtime::actor::{
    ActorAddress, Envelope, MailboxRegistry, MailboxStatusLabel, MailboxSummary,
};
use crate::runtime::Event;
use std::collections::HashMap;

/// Entry-point — invoked from `main.rs` when `command == "actors"`.
/// Returns the process exit code so main.rs can pass it to `std::process::exit`.
pub fn run(args: &[String]) -> i32 {
    let verb = args.get(2).map(|s| s.as_str()).unwrap_or("");
    let rest: Vec<String> = if args.len() > 3 { args[3..].to_vec() } else { Vec::new() };
    let (positional, json, fixture) = parse_flags(&rest);

    match verb {
        "list" => cmd_list(json, fixture),
        "show" => cmd_show(&positional, json, fixture),
        "poisoned" => cmd_poisoned(json, fixture),
        "" | "--help" | "-h" => { print_help(); 0 }
        other => {
            eprintln!("storehouse actors : unknown verb '{}' (try --help)", other);
            2
        }
    }
}

fn print_help() {
    eprintln!("Usage : storehouse actors <verb> [args] [--json] [--fixture]\n");
    eprintln!("Verbs :");
    eprintln!("  list                          — every active mailbox, table or JSON");
    eprintln!("  show <type> <id>              — detail on one mailbox");
    eprintln!("  poisoned                      — only poisoned mailboxes\n");
    eprintln!("Flags :");
    eprintln!("  --json                        — tooling-stable JSON output");
    eprintln!("  --fixture                     — render against 3 fixture mailboxes (debug)");
}

fn parse_flags(rest: &[String]) -> (Vec<String>, bool, bool) {
    let mut positional = Vec::new();
    let mut json = false;
    let mut fixture = false;
    for arg in rest {
        match arg.as_str() {
            "--json" => json = true,
            "--fixture" => fixture = true,
            _ => positional.push(arg.clone()),
        }
    }
    (positional, json, fixture)
}

fn cmd_list(json: bool, fixture: bool) -> i32 {
    let reg = gather_registry(fixture);
    let mut rows = reg.snapshot();
    rows.sort_by(|a, b| (&a.aggregate_type, &a.aggregate_id).cmp(&(&b.aggregate_type, &b.aggregate_id)));
    render_rows(&rows, json);
    0
}

fn cmd_poisoned(json: bool, fixture: bool) -> i32 {
    let reg = gather_registry(fixture);
    let mut rows = reg.snapshot_poisoned();
    rows.sort_by(|a, b| (&a.aggregate_type, &a.aggregate_id).cmp(&(&b.aggregate_type, &b.aggregate_id)));
    render_rows(&rows, json);
    0
}

fn cmd_show(positional: &[String], json: bool, fixture: bool) -> i32 {
    if positional.len() < 2 {
        eprintln!("usage : storehouse actors show <type> <id> [--json] [--fixture]");
        return 2;
    }
    let addr: ActorAddress = (positional[0].clone(), positional[1].clone());
    let reg = gather_registry(fixture);
    match reg.snapshot_one(&addr) {
        Some(row) => {
            if json {
                println!("{}", serde_json::to_string_pretty(&row.to_json()).unwrap());
            } else {
                render_one(&row);
            }
            0
        }
        None => {
            if json {
                println!("null");
            } else {
                eprintln!("no mailbox at address ({}, {})", addr.0, addr.1);
            }
            1
        }
    }
}

/// Assemble the registry the debug commands render against. Today the
/// real runtime does not own a process-wide registry ; `--fixture`
/// builds a deterministic 3-mailbox demo so the shape is exerciseable
/// from CLI and from the behaviors test. When the live runtime grows
/// a shared registry (separate sprint card), this function swaps in
/// the live source without touching anything else.
fn gather_registry(fixture: bool) -> MailboxRegistry {
    if fixture { fixture_registry() } else { MailboxRegistry::new() }
}

fn fixture_registry() -> MailboxRegistry {
    let mut reg = MailboxRegistry::new();
    // (1) Idle mailbox — one event delivered + drained cleanly. Queue
    //     depth 0, status live, events_processed 1.
    let idle = ("Sprint".to_string(), "idle".to_string());
    reg.deliver(idle.clone(), mk_env("Sprint", "idle", "Warmup", "idle-1"));
    let _ = reg.drain_all_blocking(|_| {});

    // (2) Running mailbox — envelopes still queued, never drained.
    //     Queue depth 2, status live. Delivered AFTER idle drains so
    //     the next drain (which would pull them) is never invoked.
    let running = ("Sprint".to_string(), "running".to_string());
    reg.deliver(running.clone(), mk_env("Sprint", "running", "Planned", "run-1"));
    reg.deliver(running.clone(), mk_env("Sprint", "running", "Activated", "run-2"));

    // (3) Poisoned mailbox — flip status directly via mailbox_for to
    //     avoid a second drain that would clear `running`'s queue. The
    //     mark_poisoned API is what the supervisor uses internally
    //     when catch_unwind catches a panic ; calling it here records
    //     the same audit trail (status=Poisoned, last_panic=Some).
    let poisoned = ("Sprint".to_string(), "poisoned".to_string());
    reg.deliver(poisoned.clone(), mk_env("Sprint", "poisoned", "Boom", "poison-1"));
    if let Some(mb) = reg.mailbox_for(&poisoned) {
        let mut guard = mb.lock().expect("mailbox mutex poisoned");
        guard.mark_poisoned("fixture-induced poison");
    }

    reg
}

fn mk_env(agg_type: &str, agg_id: &str, evt: &str, event_id: &str) -> Envelope {
    let event = Event {
        name: evt.to_string(),
        aggregate_type: agg_type.to_string(),
        aggregate_id: agg_id.to_string(),
        data: HashMap::new(),
    };
    Envelope::new(event, event_id)
}

fn render_rows(rows: &[MailboxSummary], json: bool) {
    if json {
        let payload: Vec<serde_json::Value> = rows.iter().map(MailboxSummary::to_json).collect();
        println!("{}", serde_json::to_string_pretty(&serde_json::Value::Array(payload)).unwrap());
        return;
    }
    if rows.is_empty() {
        println!("no mailboxes registered (try `storehouse actors list --fixture` for a demo)");
        return;
    }
    println!("{:<18} {:<14} {:<10} {:>6} {:>10}  {}",
             "TYPE", "ID", "STATUS", "QUEUE", "PROCESSED", "LAST_ERROR");
    for row in rows {
        let err = row.last_error.as_deref().unwrap_or("");
        println!("{:<18} {:<14} {:<10} {:>6} {:>10}  {}",
                 truncate(&row.aggregate_type, 18),
                 truncate(&row.aggregate_id, 14),
                 row.status.as_str(),
                 row.queue_depth,
                 row.events_processed,
                 err);
    }
    println!("\n{} mailbox(es) — {} poisoned",
             rows.len(),
             rows.iter().filter(|r| matches!(r.status, MailboxStatusLabel::Poisoned)).count());
}

fn render_one(row: &MailboxSummary) {
    println!("address           : ({}, {})", row.aggregate_type, row.aggregate_id);
    println!("status            : {}", row.status.as_str());
    println!("queue_depth       : {}", row.queue_depth);
    println!("events_processed  : {}", row.events_processed);
    println!("dropped_duplicates: {}", row.dropped_duplicates);
    if let Some(err) = &row.last_error {
        println!("last_error        : {}", err);
    }
}

fn truncate(s: &str, n: usize) -> String {
    if s.len() <= n { s.to_string() } else { format!("{}…", &s[..n.saturating_sub(1)]) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fixture_registry_has_three_mailboxes() {
        let reg = fixture_registry();
        assert_eq!(reg.active_count(), 3, "fixture must produce 3 mailboxes (idle/running/poisoned)");
        let rows = reg.snapshot();
        let kinds: Vec<&str> = rows.iter().map(|r| r.status.as_str()).collect();
        assert!(kinds.contains(&"live"), "fixture must include at least one live mailbox");
        assert!(kinds.contains(&"poisoned"), "fixture must include a poisoned mailbox");
    }

    #[test]
    fn snapshot_poisoned_filters_correctly() {
        let reg = fixture_registry();
        let poisoned = reg.snapshot_poisoned();
        assert_eq!(poisoned.len(), 1, "exactly one poisoned mailbox in the fixture");
        assert_eq!(poisoned[0].aggregate_id, "poisoned");
        assert!(poisoned[0].last_error.is_some(), "poisoned mailbox must record the panic reason");
    }

    #[test]
    fn snapshot_one_returns_none_for_unknown_address() {
        let reg = fixture_registry();
        let none = reg.snapshot_one(&("Sprint".to_string(), "nope".to_string()));
        assert!(none.is_none(), "unknown address yields None");
    }
}
