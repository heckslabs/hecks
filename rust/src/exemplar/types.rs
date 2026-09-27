// Exemplar shapes for rust/project/types.rb; see mod.rs.
// `closed_set_enum` is a one-field closed set (one variant per member); a multi-field closed
// set is a fixed data table instead.
#![allow(dead_code, unused_variables)]

// TMPL:closed_set_enum BEGIN
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TmplKind {
    // TMPL:closed_set_enum:VARIANT BEGIN
    TmplMemberA,
    // TMPL:closed_set_enum:VARIANT END
}
// TMPL:closed_set_enum END

// `plain_struct` backs value objects, entities and aggregate records alike; field types
// arrive already resolved as `TmplFieldType`.
type TmplFieldType = i64;

// TMPL:plain_struct BEGIN
#[derive(Debug, Clone, PartialEq)]
pub struct TmplType {
    // TMPL:struct_field BEGIN
    pub tmpl_field: TmplFieldType,
    // TMPL:struct_field END
}
// TMPL:plain_struct END

// `closed_set_table` — a closed set over more than one field: a `plain_struct` glued in Ruby
// to the `pub const` array, kept as two independently valid pieces.
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
