//! run_serve — warm, resident dispatch server.
//!
//! [antibody-exempt: rust/src/run_serve/mod.rs — kernel-floor runtime
//!  perf. The resident-process request handler that pays the ~660ms boot
//!  ONCE and answers every subsequent dispatch in single-digit ms. Same
//!  kernel-surface concern as sibling loop_driver.rs (a warm runtime
//!  loop) — a bluebook can't describe its own process-lifetime serving
//!  substrate. The dispatch BODY is the existing bluebook contract
//!  (Runtime::dispatch / resolve_query, byte-identical to the one-shot
//!  CLI path) ; this module only adds the parse / per-dispatch freshness
//!  / render-state wrapper around it. Two transports hang off the shared
//!  `handle_request` : `stdio` (stdin/stdout) and `socket` (unix domain
//!  socket — survives a Claude restart as an overmind daemon).]
//!
//! The cold one-shot path (`dispatch_hecksagon`) boots a fresh
//! `Runtime` per invocation — ~660ms of lazy-IR boot even though the
//! dispatch itself is microseconds. A resident serve process boots
//! ONCE, then per request :
//!
//!   1. read one request line — `Domain::Aggregate.Command k=v k=v …`
//!      (identical to the CLI's positional `<Verb> k=v …` args)
//!   2. refresh the touched (hydrated) repos from `.heki` so state a
//!      sibling daemon wrote between requests is never stale
//!      (`Runtime::refresh_hydrated_repositories_from_heki`)
//!   3. dispatch / resolve-query against the resident runtime
//!   4. write ONE sentinel-prefixed result line back, flush
//!
//! Two transports share that body :
//!   - [`stdio::run`]  — read from stdin, write to stdout. The MCP used
//!     to spawn ONE of these per server ; the warm child died on every
//!     Claude restart.
//!   - [`socket::run`] — bind a unix domain socket, accept connections,
//!     answer each over the socket. Lives as an overmind DAEMON (body),
//!     so a Claude restart rebuilds only the MCP membrane ; the warm
//!     daemon persists. The MCP becomes a thin socket CLIENT.
//!
//! ## protocol — sentinel-prefixed result line
//!
//! `Runtime::dispatch` is NOT stdout-clean : the `:claude_tool` /
//! `:exec` adapter resolvers and `storehouse_log` emit
//! free-form `println!` lines mid-dispatch. A naive newline-delimited
//! protocol would interleave those with the result JSON and corrupt
//! the stream. We therefore prefix the ONE result line with the ASCII
//! Record-Separator byte (0x1E) + `RESULT `. The client reads lines and
//! forwards only the `\x1eRESULT …` line as the answer ; every other
//! line is incidental log output it routes to its own stderr. Errors
//! use `\x1eERROR …` so the client can fall back cleanly.
//!
//! The socket transport additionally redirects the resident runtime's
//! stdout (the source of those free-form lines) to stderr before the
//! accept loop, so only the sentinel result lines ever reach a client.

use crate::runtime::{Runtime, Value};
use crate::runtime::dispatch_detail;
use std::collections::HashMap;

pub mod socket;
pub mod stdio;

// stdio transport keeps its historic name `run` for the existing
// main.rs call site (`storehouse::run_serve::run`).
pub use socket::sock_path_for_root;
pub use stdio::run;

/// ASCII Record Separator — marks the single authoritative result line
/// amid any incidental adapter/log `println!` output.
pub const RESULT_SENTINEL: &str = "\x1eRESULT ";
pub const ERROR_SENTINEL: &str = "\x1eERROR ";

/// Optional legacy-LLM resolution closure. `dispatch_hecksagon` runs a
/// post-dispatch `adapter_llm::resolve` / `resolve_ollama` pass for the
/// pre-hecksagon conversational path. Serve mirrors it through this
/// hook so warm dispatches produce byte-identical `.heki` to the cold
/// path. `None` skips it (the modern `:llm` hecksagon path fires inside
/// `Runtime::dispatch` itself and needs no hook).
pub type LegacyLlmHook<'a> = dyn Fn(&mut Runtime, &str, &str, &str) + 'a;

/// Parse + dispatch ONE request, returning the sentinel-prefixed line
/// to write. Never panics : a parse / dispatch error becomes an
/// `\x1eERROR …` line so the loop keeps serving and the client can fall
/// back gracefully. Shared by both transports.
pub(crate) fn handle_request(
    rt: &mut Runtime,
    req: &str,
    legacy_llm: Option<&LegacyLlmHook>,
) -> String {
    // THE freshness crux : reconcile the warm runtime's touched repos
    // with disk BEFORE every dispatch so concurrent daemon writes are
    // never served stale. Hydrated-only + unconditional — see the
    // method doc for why this is the right primitive for serve.
    rt.refresh_hydrated_repositories_from_heki();

    let (command, attrs_pairs) = parse_request(req);
    if command.is_empty() {
        return format!("{}{}", ERROR_SENTINEL,
            serde_json::json!({ "ok": false, "error": "empty command" }));
    }

    // Split the FQN `Domain::Aggregate.Verb` so the query check
    // compares the BARE verb against `q.name` (the IR stores it
    // unqualified) and qualified resolution targets the right same-name
    // repo. dispatch_hecksagon checks the bare name against the FULL
    // command string, so its FQN-query path silently never matches ;
    // serve resolves it correctly via resolve_query_qualified.
    let (ctx, agg, bare_verb) = split_fqn(&command);

    let is_query = rt.domain.aggregates.iter().any(|a|
        a.queries.iter().any(|q| q.name == bare_verb));

    if is_query {
        let str_attrs: HashMap<String, String> = attrs_pairs.iter()
            .map(|(k, v)| (k.clone(), v.clone())).collect();
        let result = rt.resolve_query_qualified(ctx.as_deref(), &agg, &bare_verb, &str_attrs);
        format!("{}{}", RESULT_SENTINEL, result)
    } else {
        let rt_attrs: HashMap<String, Value> = attrs_pairs.iter()
            .map(|(k, v)| (k.clone(), Value::Str(v.clone())))
            .collect();
        match rt.dispatch(&command, rt_attrs) {
            Ok(result) => {
                if let Some(hook) = legacy_llm {
                    hook(rt, &result.aggregate_type, &result.aggregate_id, &command);
                }
                // StoryExecuted / SprintExecuted projections (i528) - run the
                // story use cases (or fan out over a sprint's stories) when
                // executed THROUGH THE DOOR, mirroring the main.rs / run.rs hook.
                // route() cold-boots per step (no warm-rt borrow); serve must NOT
                // process::exit on a failing step - it is a resident server.
                if let Some(ref ev) = result.event {
                    if ev.name == "StoryExecuted" || ev.name == "SprintExecuted" {
                        let agg_id = ev.aggregate_id.clone();
                        let root = crate::storehouse_router::conception_root();
                        let heki_dir = crate::world::attach::collect_world_heki_dirs(&root)
                            .get("plan").cloned()
                            .or_else(crate::storehouse_router::info_dir);
                        if let Some(dir) = heki_dir {
                            let code = if ev.name == "SprintExecuted" {
                                crate::story_runtime::sprint_execute(
                                    &agg_id, &dir, crate::storehouse_router::route)
                            } else {
                                crate::story_runtime::storehouse_execute(
                                    &agg_id, &dir, crate::storehouse_router::route)
                            };
                            if code != 0 {
                                eprintln!("[{}] projection for {} exited {} (server continues)", ev.name, agg_id, code);
                            }
                        } else {
                            eprintln!("[{}] cannot resolve plan heki dir - projection skipped", ev.name);
                        }
                    }
                }
                // Drain the per-dispatch event timeline AFTER dispatch
                // returns (the DispatchScope Drop has already populated
                // LAST_EVENTS). Serialise as a JSON array so the MCP
                // client's `warmDispatchEnvelope` can surface them — fixes
                // the "0 events" warm-path lie (i718).
                let raw_events = dispatch_detail::take_last_events();
                let events_json: Vec<serde_json::Value> = raw_events.iter().map(|e| {
                    serde_json::json!({
                        "kind": e.kind,
                        "verb": e.verb,
                        "ok": e.ok,
                    })
                }).collect();
                let fields = render_state(rt, &result.aggregate_type, &result.aggregate_id);
                format!("{}{}", RESULT_SENTINEL, serde_json::json!({
                    "ok": true,
                    "aggregate": result.aggregate_type,
                    "id": result.aggregate_id,
                    "state": fields,
                    "events": events_json,
                }))
            }
            Err(e) => format!("{}{}", ERROR_SENTINEL, serde_json::json!({
                "ok": false,
                "error": format!("{:?}", e),
                "command": command,
            })),
        }
    }
}

/// Project the dispatched aggregate's latest state into the same JSON
/// shape `dispatch_hecksagon` emits (Str/Int/Bool pass through ;
/// everything else stringifies). Keeps the warm result byte-identical
/// to the cold path.
fn render_state(rt: &Runtime, agg_type: &str, agg_id: &str) -> serde_json::Value {
    match rt.find(agg_type, agg_id) {
        Some(s) => {
            let mut map = serde_json::Map::new();
            for (k, v) in &s.fields {
                map.insert(k.clone(), match v {
                    Value::Str(s) => serde_json::json!(s),
                    Value::Int(n) => serde_json::json!(n),
                    Value::Bool(b) => serde_json::json!(b),
                    _ => serde_json::json!(v.to_string()),
                });
            }
            serde_json::Value::Object(map)
        }
        None => serde_json::json!({}),
    }
}

/// Split a request line into `(command, [(key, value), …])`. The
/// command is the first whitespace-delimited token ; the rest are
/// `key=value` pairs (split on the FIRST `=` so values may contain `=`).
/// Tokens without `=` are ignored (matches the CLI's filter_map shape).
///
/// NOTE: this is whitespace-tokenized, identical to how the shell hands
/// argv to the one-shot path. A value containing spaces must be encoded
/// by the caller (the client stringifies scalars ; multi-word values
/// are not a supported wire shape, same as the CLI today).
fn parse_request(req: &str) -> (String, Vec<(String, String)>) {
    let mut tokens = req.split_whitespace();
    let command = tokens.next().unwrap_or("").to_string();
    let mut pairs = Vec::new();
    for tok in tokens {
        if let Some(eq) = tok.find('=') {
            let (k, v) = tok.split_at(eq);
            pairs.push((k.to_string(), v[1..].to_string()));
        }
    }
    (command, pairs)
}

/// Split a fully-qualified address `Domain::Aggregate.Verb` into
/// `(context, aggregate, bare_verb)`. Tolerant of the short forms the
/// runtime also accepts :
///   - `Domain::Aggregate.Verb` → (Some("Domain"), "Aggregate", "Verb")
///   - `Aggregate.Verb`         → (None,            "Aggregate", "Verb")
///   - `Verb`                   → (None,            "",          "Verb")
/// The `::` separates context from aggregate ; the LAST `.` separates
/// the verb. Used only for query discrimination + qualified query
/// resolution ; command dispatch keeps the full address (the runtime's
/// resolver disambiguates commands itself).
fn split_fqn(command: &str) -> (Option<String>, String, String) {
    let (head, verb) = match command.rsplit_once('.') {
        Some((h, v)) => (h, v.to_string()),
        None => return (None, String::new(), command.to_string()),
    };
    match head.split_once("::") {
        Some((ctx, agg)) => (Some(ctx.to_string()), agg.to_string(), verb),
        None => (None, head.to_string(), verb),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn split_fqn_full_form() {
        let (ctx, agg, verb) = split_fqn("Sidequest::Sidequest.Open");
        assert_eq!(ctx.as_deref(), Some("Sidequest"));
        assert_eq!(agg, "Sidequest");
        assert_eq!(verb, "Open");
    }

    #[test]
    fn split_fqn_short_aggregate_verb() {
        let (ctx, agg, verb) = split_fqn("Session.Begin");
        assert_eq!(ctx, None);
        assert_eq!(agg, "Session");
        assert_eq!(verb, "Begin");
    }

    #[test]
    fn split_fqn_bare_verb() {
        let (ctx, agg, verb) = split_fqn("Begin");
        assert_eq!(ctx, None);
        assert_eq!(agg, "");
        assert_eq!(verb, "Begin");
    }

    #[test]
    fn parse_request_command_and_pairs() {
        let (cmd, pairs) = parse_request("Inbox::Inbox.Add ref=i9 priority=low");
        assert_eq!(cmd, "Inbox::Inbox.Add");
        assert_eq!(pairs, vec![
            ("ref".to_string(), "i9".to_string()),
            ("priority".to_string(), "low".to_string()),
        ]);
    }

    #[test]
    fn parse_request_value_with_equals() {
        // split on the FIRST '=' so values may carry '='.
        let (_cmd, pairs) = parse_request("X.Y expr=a=b");
        assert_eq!(pairs, vec![("expr".to_string(), "a=b".to_string())]);
    }

    #[test]
    fn parse_request_empty() {
        let (cmd, pairs) = parse_request("   ");
        assert_eq!(cmd, "");
        assert!(pairs.is_empty());
    }
}
