//! Rust port of `lib/hecks_specializer/dump.rb`.
//!
//! Emits `hecks_life/src/dump.rs` byte-identical to the Ruby
//! specializer's output. Reads the `Serializer`, `JsonField`, and
//! `EnumCase` rows from the dump_shape fixture, sorts by `order`, and
//! dispatches each Serializer row by `body_kind`:
//!
//!   - `json_object`     — `json!({...})` body; if any field uses
//!                         `mapping_kind: fixture_pairs` the function
//!                         gains an order-preserving preamble first
//!   - `embedded_helper` — raw `.rs.frag` body interpolated between `{` `}`
//!   - `enum_match`      — hand-aligned `match` arms with padding
//!                         calculated from the widest variant
//!
//! Phase D D2 — second Rust-native specializer. Extends the D1 pilot
//! (`validator_warnings.rs`) with multi-aggregate dispatch, order
//! sorting, and the padded enum_match emitter. Every subsequent
//! Rust-emitting specializer reuses this vocabulary.
//!
//! Usage:
//!   let rust = dump::emit(repo_root)?;
//!   print!("{}", rust);

use crate::ir::Fixture;
use crate::specializer::util;
use std::error::Error;
use std::path::Path;

const SHAPE_REL: &str =
    "hecks_conception/capabilities/dump_shape/fixtures/dump_shape.fixtures";

pub fn emit(repo_root: &Path) -> Result<String, Box<dyn Error>> {
    let shape = repo_root.join(SHAPE_REL);
    let fixtures = util::load_fixtures(&shape)?;
    let serializers = util::by_aggregate_sorted(&fixtures, "Serializer", "order");

    let mut out = String::new();
    out.push_str(HEADER);
    out.push_str(IMPORTS);
    for ser in &serializers {
        out.push_str(&emit_serializer(repo_root, &fixtures, ser)?);
    }
    Ok(out)
}

const HEADER: &str = r#"//! Canonical IR dump — JSON shape that both Ruby and Rust must agree on.
//!
//! GENERATED FILE — do not edit.
//! Source:    hecks_conception/capabilities/dump_shape/
//! Regenerate: bin/specialize dump --output hecks_life/src/dump.rs
//! Contract:  specializer.hecksagon :specialize_dump shell adapter
//!
//! This is the parity contract. Hand-written so the JSON shape is chosen
//! explicitly, not accidentally derived from Rust struct field names or
//! serde defaults. When the Ruby BluebookModel serializer (canonical_ir.rb)
//! produces the same shape, both parsers can be diffed deterministically.
//!
//! Shape:
//!   { name, category, vision, aggregates[], policies[], fixtures[], vows[] }
//!
//! Each Aggregate, Command, Attribute, etc. has a fixed key order and
//! omits no fields (uses null where absent). Stable field naming —
//! `attributes[*].type` (not Rust's internal `attr_type`),
//! `references[*].target`, etc. — so the contract reads naturally.
//!
//! Usage:
//!   hecks-life dump path/to/foo.bluebook
//!   # → JSON to stdout, exit 0

"#;

const IMPORTS: &str = "use crate::ir::{
    Aggregate, Attribute, Command, Domain, Fixture, Given, Lifecycle, Mutation,
    MutationOp, Policy, Query, Reference, Transition, ValueObject,
};
use serde_json::{json, Value};

";

const NORMALIZE_DOC: &str = "\
// Strip whitespace adjacent to brackets/braces/parens. Source representations
// differ (\"[ a, b ]\" vs \"[a, b]\") even when semantically identical; both
// runtimes normalize so the canonical output agrees.
";

/// Common `fn NAME(BINDING: &TARGET) -> RET` signature prefix used by
/// every serializer body_kind. `is_entry=true` on the Dump row emits a
/// leading `pub `.
fn signature(ser: &Fixture) -> String {
    let pub_prefix = if util::attr(ser, "is_entry") == "true" { "pub " } else { "" };
    format!(
        "{}fn {}({}: &{}) -> {}",
        pub_prefix,
        util::attr(ser, "name"),
        util::attr(ser, "input_binding"),
        util::attr(ser, "target_type"),
        util::attr(ser, "return_type"),
    )
}

fn emit_serializer(
    repo_root: &Path,
    fixtures: &[Fixture],
    ser: &Fixture,
) -> Result<String, Box<dyn Error>> {
    match util::attr(ser, "body_kind") {
        "json_object" => Ok(emit_json_object(fixtures, ser)),
        "embedded_helper" => emit_embedded_helper(repo_root, ser),
        "enum_match" => Ok(emit_enum_match(fixtures, ser)),
        other => Err(format!("unknown body_kind: {}", other).into()),
    }
}

/// Render a single JSON-field line. Returns `None` when the field's
/// `mapping_kind` is `fixture_pairs` — caller replaces it with a
/// `"<key>": pairs,` reference after emitting the preamble.
fn emit_field(f: &Fixture, binding: &str) -> Option<String> {
    let key = util::attr(f, "key");
    let src = util::attr(f, "source");
    let helper = util::attr(f, "helper_fn");
    let line = match util::attr(f, "mapping_kind") {
        "direct" => format!("\"{}\": {}.{},", key, binding, src),
        "recurse_list" => format!(
            "\"{}\": {}.{}.iter().map({}).collect::<Vec<_>>(),",
            key, binding, src, helper
        ),
        "recurse_optional" => format!("\"{}\": {}.{}.as_ref().map({}),", key, binding, src, helper),
        "helper_call" => format!("\"{}\": {}(&{}.{}),", key, helper, binding, src),
        "normalize" => format!("\"{}\": normalize_value(&{}.{}),", key, binding, src),
        "fixture_pairs" => return None,
        other => panic!("unknown mapping_kind: {}", other),
    };
    Some(format!("        {}", line))
}

fn emit_json_object(fixtures: &[Fixture], ser: &Fixture) -> String {
    let binding = util::attr(ser, "input_binding");
    let fields: Vec<&Fixture> = util::by_aggregate_sorted(fixtures, "JsonField", "order")
        .into_iter()
        .filter(|f| util::attr(f, "serializer") == util::attr(ser, "name"))
        .collect();
    let pair_field = fields
        .iter()
        .find(|f| util::attr(f, "mapping_kind") == "fixture_pairs")
        .copied();

    let mut out = format!("{} {{\n", signature(ser));
    if let Some(pf) = pair_field {
        out.push_str(
            "    // Use array of [key, value] pairs to preserve order — same shape Ruby will emit.\n",
        );
        out.push_str(&format!(
            "    let pairs: Vec<Value> = {}.{}.iter()\n",
            binding,
            util::attr(pf, "source"),
        ));
        out.push_str("        .map(|(k, v)| json!([k, normalize_value(v)]))\n");
        out.push_str("        .collect();\n");
    }
    out.push_str("    json!({\n");
    let pair_key = pair_field.map(|pf| util::attr(pf, "key")).unwrap_or("");
    let lines: Vec<String> = fields
        .iter()
        .map(|f| {
            emit_field(f, binding)
                .unwrap_or_else(|| format!("        \"{}\": pairs,", pair_key))
        })
        .collect();
    out.push_str(&lines.join("\n"));
    out.push_str("\n    })\n}\n\n");
    out
}

fn emit_embedded_helper(repo_root: &Path, ser: &Fixture) -> Result<String, Box<dyn Error>> {
    let snippet_path = repo_root.join(util::attr(ser, "snippet_path"));
    let body = util::read_snippet_body(&snippet_path)?;
    let doc = if util::attr(ser, "name") == "normalize_value" { NORMALIZE_DOC } else { "" };
    Ok(format!("{}{} {{\n{}}}\n\n", doc, signature(ser), body))
}

fn emit_enum_match(fixtures: &[Fixture], ser: &Fixture) -> String {
    let serializer_name = util::attr(ser, "name");
    let cases: Vec<&Fixture> = util::by_aggregate_sorted(fixtures, "EnumCase", "order")
        .into_iter()
        .filter(|c| util::attr(c, "serializer") == serializer_name)
        .collect();
    let widest = cases.iter().map(|c| util::attr(c, "variant").len()).max().unwrap_or(0);
    let arms: Vec<String> = cases
        .iter()
        .map(|c| {
            let variant = util::attr(c, "variant");
            let pad = " ".repeat(widest - variant.len());
            format!("        {}{} => \"{}\",", variant, pad, util::attr(c, "emits"))
        })
        .collect();

    let mut out = format!("{} {{\n", signature(ser));
    out.push_str(&format!("    match {} {{\n", util::attr(ser, "input_binding")));
    out.push_str(&arms.join("\n"));
    out.push_str("\n    }\n}\n\n");
    out
}
