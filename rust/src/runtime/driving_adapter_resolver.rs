//! Sprint 14 — fires `driving on` adapters declared in
//! `<bluebook>/hecksagons/<service>.hecksagon`.
//!
//! Sibling of `driven_adapter_resolver`. Where the driven resolver
//! reacts to bus events (`driven on "Aggregate.Event"`), this one
//! reacts to EXTERNAL triggers : cron ticks, HTTP POSTs, file-system
//! changes.
//!
//! Shape :
//!
//! ```text
//! adapter "CronAdapter" do
//!   driving on cron "*/5 * * * *" do |signal|
//!     dispatch "Tools::TaskTool.Get", id: "cron-tick"
//!   end
//! end
//! ```
//!
//! v1 scope :
//!   - `cron`       — implemented end-to-end. Every call to
//!                    `fire_driving_cron_ticks` dispatches every
//!                    cron handler's follow-on commands. v1 does NOT
//!                    evaluate the cron expression ; every tick fires
//!                    every handler. Expression-aware scheduling is a
//!                    follow-up card (parse the 5-field cron grammar,
//!                    keep last-fire-at per handler, fire only when the
//!                    schedule says due).
//!   - `http_post`  — parses but is a runtime no-op. Stubbed pending
//!                    the `storehouse serve` HTTP listener wiring.
//!   - `file_watch` — parses but is a runtime no-op. Stubbed pending
//!                    inotify / fsevents integration.
//!
//! The cascade path mirrors `driven_adapter_resolver` : each declared
//! dispatch routes through `command_dispatch::dispatch_cascade` so its
//! emit reaches the bus and any downstream `driven on` chains fire.

use std::collections::HashMap;
use crate::runtime::{Runtime, Value, command_dispatch};

/// Scan attached hecksagons for `driving on cron` handlers and
/// dispatch each declared follow-on via the cascade path. No-op when
/// no hecksagons are attached, no driving adapters are declared, or
/// no cron handlers exist.
///
/// Called every tick by `LoopDriver::tick_once` for live `storehouse
/// loop` runs, and once per test by the behaviors runner for the
/// `kind: :driving_tick` discriminator (the deterministic test path
/// — there's no daemon in a pure-memory test).
pub fn fire_driving_cron_ticks(rt: &mut Runtime) {
    fire_driving_handlers(rt, "cron");
}

/// Generic single-kind firing path. Cron / HTTP / file-watch all reach
/// the runtime through the same shape ; only the trigger differs.
/// HTTP and file-watch resolvers can call this once their listeners
/// are wired ; cron uses it directly.
pub fn fire_driving_handlers(rt: &mut Runtime, kind: &str) {
    if rt.hecksagons.is_empty() { return; }
    let debug = std::env::var("HECKS_DEBUG_DRIVING").is_ok();

    // Snapshot matching dispatches up-front. The follow-on dispatch
    // takes `&mut Runtime`, so we can't keep an immutable borrow of
    // `rt.hecksagons` open across the call. Clone is cheap : driving
    // adapter declarations are small static IR.
    let matched: Vec<(String, Vec<(String, String)>)> = rt.hecksagons.iter()
        .flat_map(|h| h.driving_adapters.iter())
        .flat_map(|a| a.handlers.iter())
        .filter(|h| h.kind == kind)
        .flat_map(|h| h.dispatches.iter())
        .map(|d| (d.command.clone(), d.attrs.clone()))
        .collect();

    if matched.is_empty() { return; }

    for (command, attrs) in matched {
        let attr_map = build_attr_map(&attrs);
        // Cascade dispatch so the follow-on's emit reaches the bus.
        // External triggers have no natural upstream event ; pass the
        // synthetic "DrivingTick" / kind pair so the cascade hint
        // never resolves a same-type id (the dispatch_cascade fallback
        // is identical to `dispatch` in that case).
        let upstream_type = format!("Driving{}", capitalize(kind));
        let upstream_id = format!("{}-tick", kind);
        let outcome = command_dispatch::dispatch_cascade(
            rt,
            &command,
            attr_map,
            &upstream_type,
            &upstream_id,
        );
        if debug {
            match &outcome {
                Ok(r) => eprintln!("[driving:debug] cascaded into {} ok agg={} id={}", command, r.aggregate_type, r.aggregate_id),
                Err(e) => eprintln!("[driving:debug] cascade into {} FAILED: {:?}", command, e),
            }
        }
        let _ = outcome;
    }
}

fn capitalize(s: &str) -> String {
    let mut chars = s.chars();
    match chars.next() {
        Some(c) => c.to_uppercase().collect::<String>() + chars.as_str(),
        None => String::new(),
    }
}

/// Convert the parser's source-token attrs (string values still carry
/// surrounding quotes, ints stay as digit strings) into the runtime's
/// dynamic Value form. Mirrors `driven_adapter_resolver::build_attr_map`
/// (the dispatch attrs shape is identical between the two forms ;
/// inlined here so the two resolvers stay independent).
/// Stable identity for one driving handler across daemon restarts :
/// `<adapter>:<kind>:<arg>`. The `storehouse drive` scheduler keys its
/// per-handler last-fired tick on this, so the id must be derivable
/// identically at enumerate-time and (were it needed) fire-time.
pub fn handler_id(adapter: &str, kind: &str, arg: &str) -> String {
    format!("{}:{}:{}", adapter, kind, arg)
}

/// One enumerated driving handler ready for the drive daemon : its stable
/// id, its raw schedule arg (e.g. "2s" — the daemon parses it to a
/// Duration), and its dispatches pre-cloned as `(command, attrs)` pairs so
/// the daemon can fire them with `&mut Runtime` without re-borrowing the
/// hecksagons. Small static IR ; cloning per tick is cheap.
pub type EnumeratedHandler = (String, String, Vec<(String, Vec<(String, String)>)>);

/// Enumerate every `driving on <kind>` handler across attached hecksagons,
/// for the drive daemon. The daemon decides which are DUE (via the pure
/// drive_scheduler) and fires those with `fire_dispatches`.
pub fn enumerate_driving_handlers(rt: &Runtime, kind: &str) -> Vec<EnumeratedHandler> {
    rt.hecksagons.iter()
        .flat_map(|h| h.driving_adapters.iter())
        .flat_map(|a| a.handlers.iter().map(move |hd| (a.name.as_str(), hd)))
        .filter(|(_, hd)| hd.kind == kind)
        .map(|(adapter, hd)| {
            let id = handler_id(adapter, &hd.kind, &hd.arg);
            let dispatches = hd.dispatches.iter()
                .map(|d| (d.command.clone(), d.attrs.clone()))
                .collect();
            (id, hd.arg.clone(), dispatches)
        })
        .collect()
}

/// Fire one handler's dispatches through the cascade path — the same route
/// `fire_driving_handlers` uses, so emits reach the bus and downstream
/// `driven on` chains fire. Called by the drive daemon for each DUE handler.
pub fn fire_dispatches(rt: &mut Runtime, dispatches: &[(String, Vec<(String, String)>)]) {
    for (command, attrs) in dispatches {
        let attr_map = build_attr_map(attrs);
        let _ = command_dispatch::dispatch_cascade(
            rt,
            command,
            attr_map,
            "DrivingInterval",
            "interval-tick",
        );
    }
}

fn build_attr_map(attrs: &[(String, String)]) -> HashMap<String, Value> {
    let mut out = HashMap::new();
    for (k, raw) in attrs {
        let v = raw.trim();
        if let Ok(n) = v.parse::<i64>() {
            out.insert(k.clone(), Value::Int(n));
        } else if v == "true" {
            out.insert(k.clone(), Value::Bool(true));
        } else if v == "false" {
            out.insert(k.clone(), Value::Bool(false));
        } else {
            let s = if v.starts_with('"') && v.ends_with('"') && v.len() >= 2 {
                v[1..v.len() - 1].to_string()
            } else {
                v.to_string()
            };
            out.insert(k.clone(), Value::Str(s));
        }
    }
    out
}
