// EXEMPLAR shapes for rust/project/types.rb — see mod.rs's own header.
//
// `closed_set_enum` is the Rust reading of a `ShapeField` (shape.bluebook)
// whose owning value object closed over exactly one field (`one_of do
// member value: "credit" ... end`) — a real enum CHOICE, one variant per
// admitted member. A closed set over MORE than one field (`Statement
// Frequency`) is a different shape entirely — a fixed DATA TABLE, not a
// tag — and gets its own exemplar item once that wave lands.
#![allow(dead_code, unused_variables)]

// TMPL:closed_set_enum BEGIN
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TmplKind {
    // TMPL:closed_set_enum:VARIANT BEGIN
    TmplMemberA,
    // TMPL:closed_set_enum:VARIANT END
}
// TMPL:closed_set_enum END

// `plain_struct` — the Rust reading of a `ShapeField` LIST (a whole value
// object's/entity's/aggregate record's declared attributes), independent
// of the per-attribute `Option<T>`/`&'static str`/`Vec<T>` decision —
// that decision is already made in Ruby before a field ever reaches this
// shape (`TmplFieldType` stands for whatever fully-resolved type string
// the caller computed). Reused by plain value objects, entities, and
// aggregate records alike (all three emit the identical struct skeleton
// in real output — only which attributes and which types differ), AND
// by `closed_set_table`'s own struct half, below.
type TmplFieldType = i64;

// TMPL:plain_struct BEGIN
#[derive(Debug, Clone, PartialEq)]
pub struct TmplType {
    // TMPL:struct_field BEGIN
    pub tmpl_field: TmplFieldType,
    // TMPL:struct_field END
}
// TMPL:plain_struct END

// `closed_set_table` — the OTHER real shape a closed set can take
// (`closed_set_enum`'s own header explains the split): a fixed DATA
// TABLE when the set closes over more than one field. Its struct half
// is `plain_struct` again (String fields become `&'static str` — Ruby's
// own `TmplFieldType` computation already differs there, nothing new
// for this shape to express) glued in Ruby to the `pub const` array
// below — deliberately NOT one monolithic exemplar item: gluing two
// already-independently-valid pieces with a blank line is exactly the
// same class of plain-Ruby assembly `Exemplar.render_each`'s own
// `join_with` already does, not a new place hand-built Rust syntax risk
// creeps back in.
struct TmplRow {
    tmpl_field: i64,
}

fn tmpl_value_placeholder() -> i64 {
    0
}

fn tmpl_row_field_host() -> TmplRow {
    TmplRow {
        // TMPL:closed_set_table_row_field BEGIN
        tmpl_field: tmpl_value_placeholder()
        // TMPL:closed_set_table_row_field END
    }
}
