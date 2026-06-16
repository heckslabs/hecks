//! Grammar↔fixtures parity for the Hexagon IR (thread B).
//!
//! The byte-identity golden (specializer_golden_test) proves the
//! fixtures emit today's hecksagon_ir.rs. This proves the OTHER half :
//! the 4 grammar-modelled aggregates in hexagon.bluebook still
//! correspond, field-for-field, to the fixtures rows the generator
//! emits. Editing the grammar (a new attribute, a renamed field, a new
//! relationship) makes this test RED until codegen/hecksagon_ir_shape is
//! updated and hecksagon_ir.rs regenerated — closing the
//! double-maintenance the restart note flagged (the IR was hand-edited
//! twice in parallel with the grammar).
//!
//! The mapping is explicit because the IR is the PARSED/runtime form, not
//! a 1:1 mirror of the domain model. Two documented divergences :
//!   • Binding.phrase (grammar) is the bind's domain identity ; the
//!     parsed wiring IR drops it — grammar-only.
//!   • Binding.verb (IR) is DERIVED at parse from the adapter's family ;
//!     the grammar never declares it — ir-only.
//! A relationship maps to its IR field by an explicit table ; a NEW
//! relationship panics rather than silently passing.
//!
//! [antibody-exempt: rust/tests/hecksagon_ir_parity_test.rs — kernel-floor
//!  parity test ; asserts on parsed Rust IR + fixtures rows, necessarily
//!  Rust. Sibling of specializer_golden_test.rs.]

use std::collections::BTreeSet;
use std::fs;
use std::path::PathBuf;
use storehouse::ir::ReferenceKind;
use storehouse::parser;
use storehouse::specializer::util;

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("rust has a parent")
        .to_path_buf()
}

const GRAMMAR_REL: &str = "hecks_conception/aggregates/language/grammar/hexagon.bluebook";
const SHAPE_REL: &str = "codegen/hecksagon_ir_shape/fixtures/hecksagon_ir_shape.fixtures";

// (grammar aggregate name, IR struct name). Field -> FamilyField is the
// one name-map ; the rest share a name.
const PAIRS: &[(&str, &str)] = &[
    ("Family", "Family"),
    ("Field", "FamilyField"),
    ("Adapter", "Adapter"),
    ("Binding", "Binding"),
];

// Grammar members that intentionally have NO IR field (domain identity
// not carried into the parsed wiring IR).
fn is_grammar_only(agg: &str, member: &str) -> bool {
    matches!((agg, member), ("Binding", "phrase"))
}

// IR fields that intentionally have NO grammar member (derived at parse).
fn is_ir_only(strct: &str, field: &str) -> bool {
    matches!((strct, field), ("Binding", "verb"))
}

// A relationship's IR field name. Explicit so a NEW relationship panics
// (forcing a conscious fixtures + IR update) instead of slipping through.
fn relationship_field(agg: &str, kind: &ReferenceKind, target: &str) -> String {
    match (agg, kind, target) {
        ("Family", ReferenceKind::HasMany, "Field") => "fields".to_string(),
        ("Family", ReferenceKind::HasMany, "ProducedField") => "produces".to_string(),
        ("Adapter", ReferenceKind::BelongsTo, "Family") => "family".to_string(),
        ("Binding", ReferenceKind::HasOne, "Adapter") => "adapter".to_string(),
        _ => panic!(
            "unmapped relationship {agg} -> {target} ({kind:?}) — \
             add it to relationship_field AND codegen/hecksagon_ir_shape"
        ),
    }
}

#[test]
fn grammar_matches_hecksagon_ir_fixtures() {
    let root = repo_root();
    let src = fs::read_to_string(root.join(GRAMMAR_REL)).expect("hexagon.bluebook missing");
    let domain = parser::parse(&src);
    let fixtures = util::load_fixtures(&root.join(SHAPE_REL)).expect("fixtures load failed");

    for (gagg, strct) in PAIRS {
        let agg = domain
            .aggregates
            .iter()
            .find(|a| a.name == *gagg)
            .unwrap_or_else(|| panic!("grammar aggregate {gagg} not found"));

        // Grammar members -> expected IR field names.
        let mut grammar_fields: BTreeSet<String> = BTreeSet::new();
        for attr in &agg.attributes {
            if is_grammar_only(gagg, &attr.name) {
                continue;
            }
            grammar_fields.insert(attr.name.clone());
        }
        for r in &agg.references {
            grammar_fields.insert(relationship_field(gagg, &r.kind, &r.target));
        }

        // Fixtures IR fields for this struct.
        let mut ir_fields: BTreeSet<String> = BTreeSet::new();
        for f in &fixtures {
            if f.aggregate_name != "Field" || util::attr(f, "type_name") != *strct {
                continue;
            }
            let name = util::attr(f, "name").to_string();
            if is_ir_only(strct, &name) {
                continue;
            }
            ir_fields.insert(name);
        }

        assert_eq!(
            grammar_fields, ir_fields,
            "grammar {gagg} <-> IR {strct} drifted.\n  grammar -> {grammar_fields:?}\n  \
             fixtures -> {ir_fields:?}\n  Edited the grammar? Update \
             codegen/hecksagon_ir_shape AND regenerate hecksagon_ir.rs."
        );
    }
}
