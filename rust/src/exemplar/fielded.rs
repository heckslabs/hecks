//! Exemplar shapes for rust/codegen/src/fielded.rs (see mod.rs).
//!
//! Each `Fielded::field` arm shape is a standalone leaf so both outer skeletons can reuse it.
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

// Plain `bool` flag field read by `corrects` givens, like the lifecycle arm.
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

// The marker is the whole placeholder arm line at column 0: `render` never reindents, so leading
// whitespace would double up with Ruby's already-indented arm block.
// The two skeletons use distinct types because a second `impl Fielded` on one type is an error.
fn tmpl_arms_block() -> Option<crate::kernel::Field<'static>> {
    None
}

// `Fielded::items`: list elements for the enumeration operators, as nested or scalar fields.
fn tmpl_items_block() -> Option<Vec<crate::kernel::Field<'static>>> {
    None
}

// `Fielded::as_scalar`: a single-attribute object reads as that attribute, else `None`.
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

// The conditional `use crate::kernel::Value;` marker is the real statement, so leaving it
// unsubstituted is harmless. `#[allow(unused_imports)]` sits before the fence to stay out of it.
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
