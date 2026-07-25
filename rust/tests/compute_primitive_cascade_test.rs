//! compute_primitive_cascade_test — shrink-mod phase A, unit 1 (compute).
//!
//! The `:compute` hecksagon family is now SUGAR over the
//! `Primitive::Compute.Invoke` primitive (declared in primitive.bluebook),
//! exactly as `:exec` is sugar over `Process.Spawn` — the bespoke
//! `resolve_compute_adapters_with_excluded` resolver is retired from
//! runtime/mod.rs. This is the cascade-fires-and-lands proof the goal-a loop
//! contract requires : dispatch the triggering command, assert the compute
//! dispatcher FIRED (the function's deterministic output came back) AND the
//! `response_into` cascade LANDED that output on the target aggregate.
//!
//! The function under test is `tokenize_dream_corpus` — the registry function
//! the one real production binding (miette's dream_interpretation.hecksagon)
//! uses. Against a data_dir with no dream_state.heki it deterministically
//! returns "" (pinned by its own unit tests), so the landed payload being
//! PRESENT-and-empty proves the full fire -> run -> cascade protocol ran :
//! no fire would mean NO payload field at all (the negative control pins
//! that distinction).

use std::collections::HashMap;
use storehouse::hecksagon_parser;
use storehouse::parser;
use storehouse::runtime::{Runtime, Value};

const CORPUS: &str = r#"Hecks.bluebook "Corpus" do
  aggregate "Doc" do
    attribute :name, String
    attribute :payload, String

    command "Gather" do
      attribute :name, String
      then_set :name, to: :name
      emits "DocGathered"
    end

    command "Land" do
      reference_to Doc
      attribute :payload, String
      then_set :payload, to: :payload
      emits "DocLanded"
    end
  end
end"#;

const HEX: &str = r#"Hecks.hecksagon "Corpus" do
  adapter :compute, name: :toke do
    function "tokenize_dream_corpus"
    trigger_on "Doc.Gather"
    response_into "Doc.Land", attr: :payload
  end
end"#;

fn temp_dir(name: &str) -> String {
    let dir = std::env::temp_dir().join(format!("compute_primitive_{}_{}", std::process::id(), name));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir.to_string_lossy().into_owned()
}

#[test]
fn compute_binding_fires_the_primitive_and_the_cascade_lands() {
    let domain = parser::parse(CORPUS);
    let mut rt = Runtime::boot_with_hecksagons(
        domain,
        Some(temp_dir("fires")),
        vec![hecksagon_parser::parse(HEX)],
    );

    let mut attrs = HashMap::new();
    attrs.insert("name".to_string(), Value::Str("morning".to_string()));
    let result = rt.dispatch("Corpus::Doc.Gather", attrs).expect("Gather dispatches");

    // The dispatcher FIRED and the cascade LANDED : the originating Doc record
    // carries the payload field, populated by Doc.Land with the function's
    // deterministic empty-corpus output ("" — no dream_state.heki in the temp
    // data_dir). A missing field here would mean the cascade never fired.
    let doc = rt
        .find("Doc", &result.aggregate_id)
        .expect("the Gather doc record exists");
    let payload = doc.fields.get("payload").unwrap_or_else(|| {
        panic!(
            "payload must be landed by the Doc.Land cascade — fields: {:?}",
            doc.fields.keys().collect::<Vec<_>>()
        )
    });
    assert_eq!(
        payload,
        &Value::Str(String::new()),
        "the landed payload is the function's deterministic empty-corpus output",
    );
}

#[test]
fn without_the_binding_no_cascade_fires() {
    // Negative control — same bluebook, NO hecksagon : the payload field must
    // NOT appear, proving the positive test's field really came from the
    // compute primitive's cascade and not from the Gather dispatch itself.
    let domain = parser::parse(CORPUS);
    let mut rt = Runtime::boot_with_hecksagons(domain, Some(temp_dir("neg")), vec![]);

    let mut attrs = HashMap::new();
    attrs.insert("name".to_string(), Value::Str("morning".to_string()));
    let result = rt.dispatch("Corpus::Doc.Gather", attrs).expect("Gather dispatches");

    let doc = rt.find("Doc", &result.aggregate_id).expect("doc exists");
    assert!(
        !doc.fields.contains_key("payload"),
        "no :compute binding -> no cascade -> no payload field",
    );
}
