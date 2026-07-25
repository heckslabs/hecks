//! claude_tool_primitive_cascade_test — shrink-mod phase A, unit 3 (claude_tool).
//!
//! The `:claude_tool` hecksagon family is now SUGAR over the
//! `Primitive::ClaudeTool.Invoke` primitive (declared in primitive.bluebook) —
//! the bespoke `resolve_claude_tool_adapters` resolver is retired from
//! runtime/mod.rs. This is the cascade-fires-and-lands proof : dispatch the
//! triggering command, the binding matches, the REAL bash tool runs the
//! deterministic `echo hi`, and the (id, tool, output, exit_code, ok) outcome
//! cascades into result_into, landing the output on the originating record.
//! The negative control (no binding) pins that the primitive — not the
//! dispatch — landed it.

use std::collections::HashMap;
use storehouse::hecksagon_parser;
use storehouse::parser;
use storehouse::runtime::{Runtime, Value};

const CORPUS: &str = r#"Hecks.bluebook "Shop" do
  aggregate "Doc" do
    attribute :shell_command, String
    attribute :output, String

    command "Gather" do
      attribute :shell_command, String
      then_set :shell_command, to: :shell_command
      emits "DocGathered"
    end

    command "Land" do
      reference_to Doc
      attribute :tool, String
      attribute :output, String
      attribute :exit_code, Integer
      attribute :ok, Boolean
      then_set :output, to: :output
      emits "DocLanded"
    end
  end
end"#;

const HEX: &str = r#"Hecks.hecksagon "Shop" do
  adapter :claude_tool, command: "Doc.Gather", tool: :bash, result_into: "Doc.Land"
end"#;

#[test]
fn bash_tool_fires_and_the_cascade_lands_the_output() {
    let mut rt = Runtime::boot_with_hecksagons(
        parser::parse(CORPUS),
        None,
        vec![hecksagon_parser::parse(HEX)],
    );

    let mut attrs = HashMap::new();
    attrs.insert("shell_command".to_string(), Value::Str("echo hi".to_string()));
    let result = rt.dispatch("Shop::Doc.Gather", attrs).expect("Gather dispatches");

    let doc = rt.find("Doc", &result.aggregate_id).expect("doc exists");
    let output = doc.fields.get("output").unwrap_or_else(|| {
        panic!(
            "output must be landed by the Doc.Land cascade — fields: {:?}",
            doc.fields.keys().collect::<Vec<_>>()
        )
    });
    let text = match output {
        Value::Str(s) => s.clone(),
        other => panic!("output should be a string, got {other:?}"),
    };
    assert_eq!(
        text.trim(),
        "hi",
        "the REAL bash tool ran `echo hi` and the cascade landed its stdout",
    );
}

#[test]
fn without_the_binding_no_tool_runs() {
    let mut rt = Runtime::boot_with_hecksagons(parser::parse(CORPUS), None, vec![]);
    let mut attrs = HashMap::new();
    attrs.insert("shell_command".to_string(), Value::Str("echo hi".to_string()));
    let result = rt.dispatch("Shop::Doc.Gather", attrs).expect("Gather dispatches");
    let doc = rt.find("Doc", &result.aggregate_id).expect("doc exists");
    assert!(
        !doc.fields.contains_key("output"),
        "no :claude_tool binding -> no tool -> no landed output",
    );
}
