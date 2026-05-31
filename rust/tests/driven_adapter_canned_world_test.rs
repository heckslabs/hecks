//! Sprint 14 — memory-canned-defaults-v2 + world-wires-real-adapters-v2.
//!
//! The two stories' acceptance fixtures land in one test module because
//! they exercise the SAME resolver code path — the only difference is
//! whether a `.world` adapter binding is attached to the runtime.
//!
//! Scenario A : adapter declared in `.hecksagon` with `canned do ... end`
//!              and NO `.world` adapter entry binds it. The resolver
//!              uses the canned values as the wrapped-call return,
//!              merging them into the follow-on dispatch's attrs.
//!              Memory-by-default ; tests work out of the box.
//!
//! Scenario B : SAME adapter, but the runtime carries a `.world`
//!              `adapter "Shell" do; output "real-ack" end` binding.
//!              The resolver picks the binding's values instead of
//!              canned — same merge code path, different source.
//!              No `backend:` flag : presence IS the signal.
//!
//! The two scenarios assert the FINAL DISPATCHED ATTRS differ between
//! paths. The hand-written DSL is byte-identical across deployments ;
//! only `.world` differs. The merge path is the same code, so the
//! canned-vs-real distinction is observable only at the attr-map level.
//!
//! These tests bypass the full Runtime by reusing the resolver's
//! testable helpers (`pick_wrapped_values` + `merge_wrapped_and_declared`)
//! rather than booting a domain ; the resolver-internal unit tests in
//! src/runtime/driven_adapter_resolver.rs pin the wiring contract, and
//! these fixtures drive the parser → helper round-trip end-to-end so
//! the canned-vs-world distinction is provably load-bearing.

use storehouse::hecksagon_ir::{CannedResponse, DrivenAdapter, DrivenDispatch, DrivenHandler};
use storehouse::hecksagon_parser;
use storehouse::runtime::Value;
use storehouse::runtime::driven_adapter_resolver::{
    merge_wrapped_and_declared, pick_wrapped_values,
};
use storehouse::world::ir::AdapterBinding;
use storehouse::world::parser as world_parser;
use std::collections::HashMap;

// The same adapter shape used in both scenarios. The DSL the parser
// sees is identical between deployments ; only `.world` differs.
const SHELL_HECKSAGON: &str = r#"Hecks.hecksagon "Tools" do
  adapter "Shell" do
    driven on "Tools::ShellTool.BashRan" do |e|
      canned do
        output "canned-ack"
        exit_code 0
      end
      dispatch "Tools::TaskTool.Get", id: "shell-adapter-smoke"
    end
  end
end
"#;

/// Find the lone `Shell` adapter + its one handler. Both fixtures share
/// the same source so this lookup is identical between scenarios.
fn shell_handler(hex: &storehouse::hecksagon_ir::Hecksagon)
    -> (&DrivenAdapter, &DrivenHandler, &DrivenDispatch)
{
    assert_eq!(hex.driven_adapters.len(), 1, "expected one DrivenAdapter");
    let adapter = &hex.driven_adapters[0];
    assert_eq!(adapter.name, "Shell");
    assert_eq!(adapter.handlers.len(), 1);
    let handler = &adapter.handlers[0];
    assert_eq!(handler.dispatches.len(), 1);
    (adapter, handler, &handler.dispatches[0])
}

/// Run the resolver's value-pick + merge on the parsed handler against
/// a given optional world binding. Returns the attr-map that would be
/// passed to the follow-on dispatch.
fn run_resolver_pipeline(
    handler: &DrivenHandler,
    dispatch: &DrivenDispatch,
    world_binding: Option<&AdapterBinding>,
) -> HashMap<String, Value> {
    let world_values: Option<Vec<(String, String)>> = world_binding.map(|b| b.values.clone());
    let wrapped = pick_wrapped_values(
        world_values.as_deref(),
        handler.canned.as_ref(),
    );
    merge_wrapped_and_declared(&wrapped, &dispatch.attrs)
}

#[test]
fn fixture_a_no_world_entry_returns_canned_value_in_dispatched_attrs() {
    // Scenario A : the hecksagon parses to a DrivenHandler with a
    // `canned do` block. No `.world` binds it. The resolver's pipeline
    // (pick → merge) hands the follow-on dispatch the canned values.
    let hex = hecksagon_parser::parse(SHELL_HECKSAGON);
    let (adapter, handler, dispatch) = shell_handler(&hex);
    assert_eq!(adapter.name, "Shell");
    let canned: &CannedResponse = handler.canned.as_ref().expect("canned block");
    assert_eq!(canned.values.len(), 2, "two canned k/v pairs declared");

    // No world binding for this adapter.
    let attrs = run_resolver_pipeline(handler, dispatch, None);

    // Canned values reach the follow-on dispatch ...
    assert_eq!(
        attrs.get("output"),
        Some(&Value::Str("canned-ack".to_string())),
        "canned `output` MUST flow into the follow-on dispatch when no .world entry binds the adapter",
    );
    assert_eq!(
        attrs.get("exit_code"),
        Some(&Value::Int(0)),
        "canned `exit_code` MUST flow into the follow-on dispatch",
    );
    // ... and the static declared attrs survive alongside them.
    assert_eq!(
        attrs.get("id"),
        Some(&Value::Str("shell-adapter-smoke".to_string())),
    );
}

#[test]
fn fixture_b_world_entry_returns_real_backend_value_in_dispatched_attrs() {
    // Scenario B : the SAME hecksagon parses identically ; a `.world`
    // adapter binding declares `output "real-ack"`. The resolver picks
    // the binding's values instead of canned. The hand-written DSL is
    // byte-identical — only `.world` differs, and that flips the
    // wrapped-call return source.
    let hex = hecksagon_parser::parse(SHELL_HECKSAGON);
    let (adapter, handler, dispatch) = shell_handler(&hex);

    let world_src = r#"Hecks.world "Deployment" do
  adapter "Shell" do
    output "real-ack"
    backend_url "http://shell.local:9000"
  end
end
"#;
    let world = world_parser::parse(world_src);
    let binding = world.adapter_binding_for("Shell").expect("world adapter binding");
    assert_eq!(binding.name, adapter.name, "world binding matches adapter name verbatim");

    let attrs = run_resolver_pipeline(handler, dispatch, Some(binding));

    // World values reach the follow-on dispatch ...
    assert_eq!(
        attrs.get("output"),
        Some(&Value::Str("real-ack".to_string())),
        ".world `output` MUST flow into the follow-on dispatch when the binding is present",
    );
    // ... and the binding's OWN config (backend_url) reaches the
    // dispatch too, proving the binding carries deployment-specific
    // config (URL, env-var, etc.).
    assert_eq!(
        attrs.get("backend_url"),
        Some(&Value::Str("http://shell.local:9000".to_string())),
    );
    // The canned `exit_code` does NOT reach the dispatch ; world wins.
    // (canned declared exit_code: 0 ; world is silent on exit_code, so
    // the slot stays empty rather than falling back to canned.)
    assert!(
        !attrs.contains_key("exit_code"),
        ".world entry bypasses canned entirely — no per-key fall-through",
    );
    // The static declared attrs survive.
    assert_eq!(
        attrs.get("id"),
        Some(&Value::Str("shell-adapter-smoke".to_string())),
    );

    // Cross-check : the two scenarios DIFFER in dispatched output ;
    // that's the load-bearing proof that .world wiring actually flips
    // the source.
    let canned_attrs = run_resolver_pipeline(handler, dispatch, None);
    assert_ne!(
        canned_attrs.get("output"),
        attrs.get("output"),
        "the canned and world fixtures MUST produce observably different `output` values",
    );
}
