// EXEMPLAR shapes for rust/project/fielded.rb — see mod.rs's own header.
//
// `Fielded::field`'s per-attribute match arm has SIX distinct real
// shapes, driven by `ShapeField`'s own `list`/`optional` axes crossed
// against whether the field is a scalar or a nested value object —
// `emit_fielded_flat`'s own header names the same six; `emit_fielded_
// record`'s blanket-Option-wrap collapses to the SAME four of them
// (its `scalar`/`nested` arms reuse flat's `optional_scalar`/
// `optional_nested` shapes verbatim, since every record field is
// Option-wrapped regardless of the IR's own `optional:` flag). Plus a
// seventh, `fielded_lifecycle_arm`, shared between `emit_record`'s own
// lifecycle arm and `emit_entity`'s `extra_arms:` lifecycle arm — same
// text, two different Ruby call sites.
//
// All seven are standalone top-level leaves, not nested inside either
// outer skeleton (`fielded_flat`/`fielded_record`, below) — reused
// across BOTH outers, so nesting would mean physically duplicating each
// one's source into both (`json.rs`'s `to_json_field` header explains
// the same choice at length). Each host below exists ONLY to give its
// one arm a real, differently-shaped field to operate on; none of the
// seven need to coexist on one real struct, so each gets its own small
// host type rather than forcing one shared struct into seven
// incompatible shapes at once.
//
// TWO markers per arm, not one — `"tmpl_field"` (the quoted match
// pattern, a JSON key) and `tmpl_ident` (the bare `self.` field access,
// a Rust identifier) — because `naming.rb`'s own `rust_field`/
// `rust_ident_field` are NOT always the same string: a field literally
// named after a Rust keyword (`type`, `match`, ...) gets `r#type` as its
// identifier while the JSON key stays plain `"type"`. Conflating the two
// into one marker would put the escaped `r#`-identifier inside the
// quoted key too — wrong, and a real (if rare) corpus-breaking bug this
// split avoids rather than risks.
#![allow(dead_code, unused_variables)]

fn tmpl_value_expr_placeholder(v: &i64) -> crate::kernel::Value {
    crate::kernel::Value::Int(*v)
}

struct TmplListOptionalHost {
    tmpl_ident: Option<Vec<i64>>,
}
impl TmplListOptionalHost {
    fn arm(&self) -> Option<crate::kernel::Field<'_>> {
        use crate::kernel::Field;
        use crate::kernel::Value;
        match "x" {
            // TMPL:fielded_arm_list_optional BEGIN
            "tmpl_field" => self.tmpl_ident.as_ref().map(|v| Field::Value(Value::List(v.len()))).or(Some(Field::Value(Value::Nil))),
            // TMPL:fielded_arm_list_optional END
            _ => None,
        }
    }
}

struct TmplListHost {
    tmpl_ident: Vec<i64>,
}
impl TmplListHost {
    fn arm(&self) -> Option<crate::kernel::Field<'_>> {
        use crate::kernel::Field;
        use crate::kernel::Value;
        match "x" {
            // TMPL:fielded_arm_list BEGIN
            "tmpl_field" => Some(Field::Value(Value::List(self.tmpl_ident.len()))),
            // TMPL:fielded_arm_list END
            _ => None,
        }
    }
}

struct TmplOptionalScalarHost {
    tmpl_ident: Option<i64>,
}
impl TmplOptionalScalarHost {
    fn arm(&self) -> Option<crate::kernel::Field<'_>> {
        use crate::kernel::Field;
        use crate::kernel::Value;
        match "x" {
            // TMPL:fielded_arm_optional_scalar BEGIN
            "tmpl_field" => self.tmpl_ident.as_ref().map(|v| Field::Value(tmpl_value_expr_placeholder(v))).or(Some(Field::Value(Value::Nil))),
            // TMPL:fielded_arm_optional_scalar END
            _ => None,
        }
    }
}

struct TmplNestedInner;
impl crate::kernel::Fielded for TmplNestedInner {
    fn field(&self, name: &str) -> Option<crate::kernel::Field<'_>> {
        None
    }
}
struct TmplOptionalNestedHost {
    tmpl_ident: Option<TmplNestedInner>,
}
impl TmplOptionalNestedHost {
    fn arm(&self) -> Option<crate::kernel::Field<'_>> {
        use crate::kernel::Field;
        use crate::kernel::Value;
        match "x" {
            // TMPL:fielded_arm_optional_nested BEGIN
            "tmpl_field" => self.tmpl_ident.as_ref().map(|v| Field::Nested(v)).or(Some(Field::Value(Value::Nil))),
            // TMPL:fielded_arm_optional_nested END
            _ => None,
        }
    }
}

struct TmplScalarHost {
    tmpl_ident: i64,
}
impl TmplScalarHost {
    fn arm(&self) -> Option<crate::kernel::Field<'_>> {
        use crate::kernel::Field;
        match "x" {
            // TMPL:fielded_arm_scalar BEGIN
            "tmpl_field" => Some(Field::Value(tmpl_value_expr_placeholder(&self.tmpl_ident))),
            // TMPL:fielded_arm_scalar END
            _ => None,
        }
    }
}

struct TmplNestedHost {
    tmpl_ident: TmplNestedInner,
}
impl TmplNestedHost {
    fn arm(&self) -> Option<crate::kernel::Field<'_>> {
        use crate::kernel::Field;
        match "x" {
            // TMPL:fielded_arm_nested BEGIN
            "tmpl_field" => Some(Field::Nested(&self.tmpl_ident)),
            // TMPL:fielded_arm_nested END
            _ => None,
        }
    }
}

struct TmplLifecycleHost {
    tmpl_ident: String,
}
impl TmplLifecycleHost {
    fn arm(&self) -> Option<crate::kernel::Field<'_>> {
        use crate::kernel::Field;
        use crate::kernel::Value;
        match "x" {
            // TMPL:fielded_lifecycle_arm BEGIN
            "tmpl_field" => Some(Field::Value(Value::Str(self.tmpl_ident.clone()))),
            // TMPL:fielded_lifecycle_arm END
            _ => None,
        }
    }
}

// `corrects`'s own per-record flag field — a plain, non-optional `bool`
// (`Copy`, no `.clone()` needed), exactly like the lifecycle arm above
// but for `Value::Bool` instead of `Value::Str`. Read by `Expr::Lookup`
// inside a `corrects`-declaring command's own synthetic GivenSpec
// (`commands.rb`'s own `corrects_given_specs`) the same generic way any
// other given predicate reads any other record field.
struct TmplCorrectsFlagHost {
    tmpl_ident: bool,
}
impl TmplCorrectsFlagHost {
    fn arm(&self) -> Option<crate::kernel::Field<'_>> {
        use crate::kernel::Field;
        use crate::kernel::Value;
        match "x" {
            // TMPL:fielded_corrects_flag_arm BEGIN
            "tmpl_field" => Some(Field::Value(Value::Bool(self.tmpl_ident))),
            // TMPL:fielded_corrects_flag_arm END
            _ => None,
        }
    }
}

// The two outer skeletons. Unlike `to_json_field`'s own outer (json.rs),
// a bare function-call marker can't stand in for "zero or more match
// arms" — a match arm is `pattern => expr,`, not an expression on its
// own, so the marker here is the WHOLE placeholder arm line
// (`"tmpl_arms_placeholder" => tmpl_arms_block(),`), matched and
// replaced wholesale the same way `TmplRow { ... }`'s own whole-span
// markers work elsewhere. Ruby supplies the fully rendered, already-
// 12-space-indented real arm block in its place (matching the ORIGINAL
// hand-built string's own fixed indent, not an auto-reindented one —
// see json.rs's `closed_set_table_codec` header for why plain `render`
// is correct here, not `compose`/`assemble`). The marker line itself
// sits at COLUMN 0 below, not indented like its match-arm siblings —
// `render` never reindents a multi-line replacement, so any leading
// whitespace on the marker's OWN line would double up with Ruby's
// already-indented block on its first line only (found live: the first
// arm came out 24 spaces deep, every arm after it 12).
// TWO DIFFERENT placeholder types, not one — `impl Fielded for X` twice
// on the SAME type is a duplicate-impl error regardless of the fact the
// two real Ruby functions never fire for the same struct (json.rs's
// `TmplTableRow`-vs-`TmplKind` split is the same story).
fn tmpl_arms_block() -> Option<crate::kernel::Field<'static>> {
    None
}

// THE ITEMS HALF — `Fielded::items` (kernel/expr.rs), the elements of a
// list-typed field for the enumeration operators (`.any?`/`.none?`/
// `.all?`/`.find { |x| … }`), beside `field`'s own `Value::List(len)`
// reading of the same attribute. Four arm shapes: the element is either
// a nested value object/entity (`Field::Nested`) or a scalar
// (`Field::Value`, through the same `scalar_to_value` the scalar field
// arms use), crossed with the list being plain or `Option`-wrapped.
// Every `Fielded` impl carries the method; a struct with no list
// attribute renders it with no arms at all, just the `_ => None` floor.
fn tmpl_items_block() -> Option<Vec<crate::kernel::Field<'static>>> {
    None
}

// `Fielded::as_scalar` — `Resolver#unwrap_scalar`, read directly: an
// object with exactly ONE declared attribute READS AS that attribute's
// value, whatever it is named (a chess piece's `color == "white"`, its
// Color a single-field closed set; a `Money{amount}` its amount —
// single-element value objects strictly answer `.value`). Rendered as
// the sole attribute's own scalar for exactly that shape and `None`
// for every other (multi-field structs, and a sole attribute that is
// itself nested), the kernel's existing "refuse — nothing generated
// does this" reading.
fn tmpl_as_scalar_placeholder() -> Option<crate::kernel::Value> {
    None
}

struct TmplItemsNestedHost {
    tmpl_ident: Vec<TmplNestedInner>,
}
impl TmplItemsNestedHost {
    fn arm(&self) -> Option<Vec<crate::kernel::Field<'_>>> {
        #[allow(unused_imports)]
        use crate::kernel::{Field, Value};
        match "x" {
            // TMPL:fielded_items_arm_list_nested BEGIN
            "tmpl_field" => Some(self.tmpl_ident.iter().map(|v| Field::Nested(v)).collect()),
            // TMPL:fielded_items_arm_list_nested END
            _ => None,
        }
    }
}

struct TmplItemsScalarHost {
    tmpl_ident: Vec<i64>,
}
impl TmplItemsScalarHost {
    fn arm(&self) -> Option<Vec<crate::kernel::Field<'_>>> {
        #[allow(unused_imports)]
        use crate::kernel::{Field, Value};
        match "x" {
            // TMPL:fielded_items_arm_list_scalar BEGIN
            "tmpl_field" => Some(self.tmpl_ident.iter().map(|v| Field::Value(tmpl_value_expr_placeholder(v))).collect()),
            // TMPL:fielded_items_arm_list_scalar END
            _ => None,
        }
    }
}

struct TmplItemsOptionalNestedHost {
    tmpl_ident: Option<Vec<TmplNestedInner>>,
}
impl TmplItemsOptionalNestedHost {
    fn arm(&self) -> Option<Vec<crate::kernel::Field<'_>>> {
        #[allow(unused_imports)]
        use crate::kernel::{Field, Value};
        match "x" {
            // TMPL:fielded_items_arm_list_optional_nested BEGIN
            "tmpl_field" => self.tmpl_ident.as_ref().map(|items| items.iter().map(|v| Field::Nested(v)).collect()),
            // TMPL:fielded_items_arm_list_optional_nested END
            _ => None,
        }
    }
}

struct TmplItemsOptionalScalarHost {
    tmpl_ident: Option<Vec<i64>>,
}
impl TmplItemsOptionalScalarHost {
    fn arm(&self) -> Option<Vec<crate::kernel::Field<'_>>> {
        #[allow(unused_imports)]
        use crate::kernel::{Field, Value};
        match "x" {
            // TMPL:fielded_items_arm_list_optional_scalar BEGIN
            "tmpl_field" => self.tmpl_ident.as_ref().map(|items| items.iter().map(|v| Field::Value(tmpl_value_expr_placeholder(v))).collect()),
            // TMPL:fielded_items_arm_list_optional_scalar END
            _ => None,
        }
    }
}

struct TmplFlatType;
struct TmplRecordType;

// The marker for the CONDITIONAL `use crate::kernel::Value;` (present
// only when at least one real arm actually needs it) is the real
// statement text itself, not a `tmpl_`-prefixed token — a bare
// identifier there wouldn't compile unsubstituted, and unlike every
// other marker this one is SAFE to leave un-caught by the leftover-scan
// if a caller ever forgot it: the worst case is an always-present,
// harmless unused import (every generated file already tolerates
// `unused_imports` warnings — `#![allow(dead_code, unused_variables)]`
// doesn't even silence them, and the build already carries dozens from
// unrelated generated files). Ruby substitutes either this exact text
// (no-op) or an empty string, mirroring the original's own conditional
// interpolation — including that a FALSE condition leaves a genuinely
// BLANK line behind, not a removed one.
// `#[allow(unused_imports)]` sits BEFORE the fence, not inside it — real
// substituted output DOES use `Field`/`Value` (the real arms reference
// them); only this UNSUBSTITUTED exemplar's own placeholder arm doesn't,
// since `tmpl_arms_block()` already returns `Option<Field>` without
// naming `Field` bare. An attribute before `// TMPL: BEGIN` silences the
// warning here without becoming part of what gets extracted.
#[allow(unused_imports)]
// TMPL:fielded_flat BEGIN
impl crate::kernel::Fielded for TmplFlatType {
    fn field(&self, name: &str) -> Option<crate::kernel::Field<'_>> {
        use crate::kernel::Field;
        use crate::kernel::Value;
        match name {
"tmpl_arms_placeholder" => tmpl_arms_block(),
            _ => None,
        }
    }

    fn items(&self, name: &str) -> Option<Vec<crate::kernel::Field<'_>>> {
        #[allow(unused_imports)]
        use crate::kernel::{Field, Value};
        match name {
"tmpl_items_placeholder" => tmpl_items_block(),
            _ => None,
        }
    }

    fn as_scalar(&self) -> Option<crate::kernel::Value> {
        tmpl_as_scalar_placeholder()
    }
}
// TMPL:fielded_flat END

#[allow(unused_imports)]
// TMPL:fielded_record BEGIN
impl crate::kernel::Fielded for TmplRecordType {
    fn field(&self, name: &str) -> Option<crate::kernel::Field<'_>> {
        use crate::kernel::{Field, Value};
        match name {
"tmpl_arms_placeholder" => tmpl_arms_block(),
            _ => None,
        }
    }

    fn items(&self, name: &str) -> Option<Vec<crate::kernel::Field<'_>>> {
        #[allow(unused_imports)]
        use crate::kernel::{Field, Value};
        match name {
"tmpl_items_placeholder" => tmpl_items_block(),
            _ => None,
        }
    }

    fn as_scalar(&self) -> Option<crate::kernel::Value> {
        tmpl_as_scalar_placeholder()
    }
}
// TMPL:fielded_record END
