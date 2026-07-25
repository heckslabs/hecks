//! mcp_primitive_route_test — shrink-mod phase A, unit 2 (mcp).
//!
//! The `:mcp` hecksagon family is now SUGAR over the
//! `Primitive::McpTool.Invoke` primitive (declared in primitive.bluebook) —
//! the bespoke `resolve_mcp_adapters` resolver is retired from runtime/mod.rs.
//!
//! The deterministic proof rides transport-C (the world-declared route) : the
//! sugar must MATCH the binding, COMPOSE the arguments ({attr} substitution
//! against upstream state ∪ dispatch attrs), and the engine must ROUTE the
//! call — emitting the `mcp_dispatch_requested` event that carries the
//! result_into target and the invocation id (the cascade join the harness
//! transport lands on). The event lands on the `storehouse follow` file sink,
//! which STOREHOUSE_LOG_FILE points at a temp file here — so the assertion
//! reads the actual emitted routing record, not a mock. The local-spawn
//! branch (server :storehouse — a node stdio process) is deliberately not
//! exercised : a fast test must not spawn node ; the engine code path up to
//! the transport fork is shared and proven here.
//!
//! Phase 2 of the same test : an unresolvable server (neither world-declared
//! nor spawnable) must SKIP gracefully — the dispatch still succeeds and no
//! routing event is emitted — pinning the retired resolver's graceful guard.

use std::collections::HashMap;
use storehouse::hecksagon_parser;
use storehouse::parser;
use storehouse::runtime::{Runtime, Value};
use storehouse::world::ir::McpServer;

const CORPUS: &str = r#"Hecks.bluebook "Mailer" do
  aggregate "Doc" do
    attribute :name, String

    command "Gather" do
      attribute :name, String
      then_set :name, to: :name
      emits "DocGathered"
    end
  end
end"#;

const HEX_WORLD: &str = r#"Hecks.hecksagon "Mailer" do
  adapter :mcp, command: "Doc.Gather", server: :testworld, tool: "search", args: "{\"q\":\"{name}\"}", result_into: "Doc.Land"
end"#;

const HEX_UNKNOWN: &str = r#"Hecks.hecksagon "Mailer" do
  adapter :mcp, command: "Doc.Gather", server: :nowhere, tool: "search", args: "{}", result_into: "Doc.Land"
end"#;

#[test]
fn world_route_emits_the_dispatch_request_and_unknown_server_skips() {
    // Own the file sink BEFORE any sink initialisation in this process.
    let log = std::env::temp_dir().join(format!("mcp_primitive_route_{}.log", std::process::id()));
    let _ = std::fs::remove_file(&log);
    std::env::set_var("STOREHOUSE_LOG_FILE", &log);

    // ── Phase 1 : world-declared server routes ──
    let mut rt = Runtime::boot_with_hecksagons(
        parser::parse(CORPUS),
        None,
        vec![hecksagon_parser::parse(HEX_WORLD)],
    );
    rt.world_servers.push(McpServer {
        name: "testworld".to_string(),
        token_env: None,
    });

    let mut attrs = HashMap::new();
    attrs.insert("name".to_string(), Value::Str("ocean".to_string()));
    let result = rt.dispatch("Mailer::Doc.Gather", attrs).expect("Gather dispatches");

    let content = std::fs::read_to_string(&log).unwrap_or_default();
    let line = content
        .lines()
        .find(|l| l.contains("mcp_dispatch_requested"))
        .unwrap_or_else(|| panic!("expected an mcp_dispatch_requested event in the sink — got: {content}"));
    let ev: serde_json::Value = serde_json::from_str(line).expect("routing event is JSON");
    assert_eq!(ev["server"], "testworld", "the world-declared server was resolved");
    assert_eq!(ev["tool"], "search");
    assert_eq!(
        ev["args"]["q"], "ocean",
        "the sugar substituted {{name}} from the dispatch attrs before the primitive ran",
    );
    assert_eq!(
        ev["result_into"], "Doc.Land",
        "the cascade landing target rides the routing event — the harness transport joins on it",
    );
    assert_eq!(
        ev["invocation_id"], serde_json::json!(result.aggregate_id),
        "the invocation id is the originating record's id — the cascade join key",
    );

    // ── Phase 2 : unresolvable server skips gracefully ──
    let mut rt2 = Runtime::boot_with_hecksagons(
        parser::parse(CORPUS),
        None,
        vec![hecksagon_parser::parse(HEX_UNKNOWN)],
    );
    let mut attrs2 = HashMap::new();
    attrs2.insert("name".to_string(), Value::Str("ocean".to_string()));
    rt2.dispatch("Mailer::Doc.Gather", attrs2)
        .expect("dispatch still succeeds when the server is unresolvable — graceful skip");
    let content2 = std::fs::read_to_string(&log).unwrap_or_default();
    assert!(
        !content2.contains("\"server\":\"nowhere\""),
        "an unresolvable server must not emit a routing event",
    );
}
