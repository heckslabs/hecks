//! Port of the retired Ruby generator's `bridging.rb`: cross-type coercion checks for `:set` and `:append` RHS.

use crate::json::{Json, Number};
use crate::literal::Literal;
use crate::naming;
use std::collections::{HashMap, HashSet};

/// `use` lines for value objects this aggregate's commands reference but never declare locally.
/// A locally declared type name is never foreign.
pub fn cross_aggregate_vo_imports(
    aggregate: &Json,
    domain_value_object_owner: &HashMap<String, String>,
    mod_name: &str,
) -> Vec<String> {
    let local_names: HashSet<String> = aggregate
        .get("value_objects")
        .map_or_default(Json::each)
        .iter()
        .map(|vo| {
            vo.get("name")
                .and_then(Json::as_str)
                .unwrap_or("")
                .to_string()
        })
        .collect();

    let commands = aggregate.get("commands").map_or_default(Json::each);
    let entity_commands = aggregate
        .get("entities")
        .map_or_default(Json::each)
        .iter()
        .flat_map(|e| e.get("commands").map_or_default(Json::each).iter());
    let port_operations = aggregate
        .get("ports")
        .map_or_default(Json::each)
        .iter()
        .flat_map(|p| p.get("operations").map_or_default(Json::each).iter());

    let mut foreign_types: Vec<String> = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    for c in commands
        .iter()
        .chain(entity_commands)
        .chain(port_operations)
    {
        for attr in c.get("attributes").map_or_default(Json::each) {
            let type_name = crate::attr::type_name(attr).to_string();
            if local_names.contains(&type_name) || seen.contains(&type_name) {
                continue;
            }
            seen.insert(type_name.clone());
            foreign_types.push(type_name);
        }
    }

    let mut pairs: Vec<(String, String)> = foreign_types
        .into_iter()
        .filter_map(|type_name| {
            domain_value_object_owner
                .get(&type_name)
                .map(|owner| (type_name, owner.clone()))
        })
        .collect();
    pairs.sort_by(|(a_type, a_owner), (b_type, b_owner)| (a_owner, a_type).cmp(&(b_owner, b_type)));
    pairs
        .into_iter()
        .map(|(type_name, owner)| {
            format!(
                "use crate::generated::{mod_name}::{}::{};",
                naming::aggregate_module(&owner),
                naming::rust_ident(&type_name)
            )
        })
        .collect()
}

/// True when a value object rebuilds into a differently-named one by matching field names.
pub fn vo_field_bridgeable(source_vo: Option<&Json>, target_vo: Option<&Json>) -> bool {
    let (Some(source_vo), Some(target_vo)) = (source_vo, target_vo) else {
        return false;
    };
    if source_vo.get("closed_set").is_some_and(Json::as_bool)
        || target_vo.get("closed_set").is_some_and(Json::as_bool)
    {
        return closed_set_bridge_members(source_vo, target_vo).is_some();
    }

    let source_attrs = source_vo.get("attributes").map_or_default(Json::each);
    let target_attrs = target_vo.get("attributes").map_or_default(Json::each);
    target_attrs.iter().all(|t_attr| {
        let t_name = crate::attr::name(t_attr);
        source_attrs
            .iter()
            .any(|s_attr| crate::attr::name(s_attr) == t_name)
            || crate::attr::default(t_attr).is_some()
    })
}

/// Closed-set to closed-set bridge, admitted only when every source member is a target member.
fn closed_set_bridge_members<'a>(source_vo: &'a Json, target_vo: &Json) -> Option<&'a [Json]> {
    let closed = |vo: &Json| vo.get("closed_set").is_some_and(Json::as_bool);
    if !closed(source_vo) || !closed(target_vo) {
        return None;
    }
    let single = |vo: &Json| vo.get("attributes").map_or_default(Json::each).len() == 1;
    if !single(source_vo) || !single(target_vo) {
        return None;
    }
    let target_values: Vec<String> = target_vo
        .get("members")
        .map_or_default(Json::each)
        .iter()
        .map(closed_set_row_value)
        .collect();
    let source_rows = source_vo.get("members").map_or_default(Json::each);
    if source_rows
        .iter()
        .all(|row| target_values.contains(&closed_set_row_value(row)))
    {
        Some(source_rows)
    } else {
        None
    }
}

fn closed_set_row_value(row: &Json) -> String {
    let pairs = row.as_array().unwrap_or(&[]);
    let first = pairs.first().and_then(Json::as_array).unwrap_or(&[]);
    first.get(1).map(Json::to_s).unwrap_or_default()
}

#[allow(
    clippy::unwrap_used,
    reason = "the value was checked just before; None would mean invalid IR"
)]
pub fn vo_field_rhs(
    source_expr: &str,
    source_vo: &Json,
    target_type: &str,
    value_objects_by_name: &HashMap<String, &Json>,
) -> String {
    let target_vo = value_objects_by_name[target_type];
    if let Some(rows) = closed_set_bridge_members(source_vo, target_vo) {
        let source_type = source_vo.get("name").map(Json::to_s).unwrap_or_default();
        let arms: Vec<String> = rows
            .iter()
            .map(|row| {
                format!(
                    "{}::{} => {}::{}",
                    naming::rust_ident(&source_type),
                    closed_set_variant_of_row(row),
                    naming::rust_ident(target_type),
                    closed_set_variant_of_row(row)
                )
            })
            .collect();
        return format!("match &{source_expr} {{ {} }}", arms.join(", "));
    }
    let source_attrs = source_vo.get("attributes").map_or_default(Json::each);
    let target_attrs = target_vo.get("attributes").map_or_default(Json::each);

    let fields: Vec<String> = target_attrs
        .iter()
        .map(|t_attr| {
            let field = naming::rust_ident_field(crate::attr::name(t_attr));
            let t_name = crate::attr::name(t_attr);
            if source_attrs
                .iter()
                .any(|s_attr| crate::attr::name(s_attr) == t_name)
            {
                format!("{field}: {source_expr}.{field}.clone()")
            } else {
                format!(
                    "{field}: {}",
                    naming::literal_rhs(crate::attr::default(t_attr).unwrap())
                )
            }
        })
        .collect();
    format!(
        "{} {{ {} }}",
        naming::rust_ident(target_type),
        fields.join(", ")
    )
}

pub fn bridgeable_value_types(
    source_type: &str,
    target_type: &str,
    value_objects_by_name: &HashMap<String, &Json>,
) -> bool {
    if source_type == target_type {
        return true;
    }
    if let (Some(s), Some(t)) = (
        naming::effective_scalar_type(source_type),
        naming::effective_scalar_type(target_type),
    ) {
        if s == t {
            return true;
        }
    }

    let source_vo = value_objects_by_name.get(source_type).copied();
    let target_vo = value_objects_by_name.get(target_type).copied();
    if let Some(target_vo) = target_vo {
        return vo_field_bridgeable(source_vo, Some(target_vo));
    }

    match source_vo {
        Some(vo) => {
            let closed = vo.get("closed_set").is_some_and(Json::as_bool);
            let attrs = vo.get("attributes").map_or_default(Json::each);
            if closed || attrs.len() != 1 {
                return false;
            }
            let unwrapped_type = crate::attr::type_name(&attrs[0]);
            unwrapped_type == target_type
                || matches!(
                    (naming::effective_scalar_type(unwrapped_type), naming::effective_scalar_type(target_type)),
                    (Some(s), Some(t)) if s == t
                )
        }
        None => false,
    }
}

#[allow(
    clippy::expect_used,
    clippy::panic,
    reason = "a drifted exemplar or invalid IR aborts generation on purpose; the message names an invariant an earlier check in this generator established"
)]
pub fn value_rhs(
    source_expr: &str,
    source_type: &str,
    target_type: &str,
    value_objects_by_name: &HashMap<String, &Json>,
) -> String {
    if source_type == target_type {
        return format!("{source_expr}.clone()");
    }
    if let (Some(s), Some(t)) = (
        naming::effective_scalar_type(source_type),
        naming::effective_scalar_type(target_type),
    ) {
        if s == t {
            return format!("{source_expr}.clone()");
        }
    }

    let source_vo = value_objects_by_name.get(source_type).copied();
    let target_vo = value_objects_by_name.get(target_type).copied();
    if target_vo.is_some() {
        return vo_field_rhs(
            source_expr,
            source_vo.expect("bridgeable_value_types? should have caught this"),
            target_type,
            value_objects_by_name,
        );
    }

    let source_vo = source_vo.unwrap_or_else(|| panic!("unsupported coercion {source_type} -> {target_type} — bridgeable_value_types? should have caught this"));
    let attrs = source_vo.get("attributes").map_or_default(Json::each);
    assert!(!(source_vo.get("closed_set").is_some_and(Json::as_bool) || attrs.len() != 1), "unsupported coercion {source_type} -> {target_type} — bridgeable_value_types? should have caught this");
    format!(
        "{source_expr}.{}.clone()",
        naming::rust_ident_field(crate::attr::name(&attrs[0]))
    )
}

/// True when a list-to-list `:set` needs a per-element rebuild rather than one `.clone()`.
/// Sides sharing a Rust representation (`Vec<T>` or `Option<Vec<T>>`) must stay a whole clone.
pub fn list_bridge_requires_element_mapping(source_type: &str, target_type: &str) -> bool {
    if source_type == target_type {
        return false;
    }
    !matches!(
        (naming::effective_scalar_type(source_type), naming::effective_scalar_type(target_type)),
        (Some(s), Some(t)) if s == t
    )
}

/// `value_rhs` applied per element, for list-to-list `:set` whose element types differ.
pub fn list_value_rhs(
    source_expr: &str,
    source_type: &str,
    target_type: &str,
    value_objects_by_name: &HashMap<String, &Json>,
) -> String {
    format!(
        "{source_expr}.iter().map(|item| {}).collect()",
        value_rhs("item", source_type, target_type, value_objects_by_name)
    )
}

pub fn literal_set_bridgeable(
    value: &Literal,
    target_type: Option<&str>,
    value_objects_by_name: &HashMap<String, &Json>,
) -> bool {
    match value {
        Literal::Hash(_) => target_type.is_some_and(|target_type| {
            literal_hash_bridgeable(value, target_type, value_objects_by_name)
        }),
        Literal::Str(_) | Literal::Int(_) | Literal::Float(_) | Literal::Bool(_) => {
            let Some(target_type) = target_type else {
                return true;
            };
            if !value_objects_by_name.contains_key(target_type) {
                return true;
            }
            // A scalar literal into a single-field value object is that field's value.
            crate::json_codec::sole_field_of(target_type, value_objects_by_name).is_some_and(
                |sole| {
                    literal_hash_bridgeable(
                        &Literal::Hash(vec![(sole, value.clone())]),
                        target_type,
                        value_objects_by_name,
                    )
                },
            )
        }
        _ => false,
    }
}

/// Renders a literal as the right-hand side for a target type.
pub fn literal_rhs_for(
    value: &Literal,
    target_type: Option<&str>,
    value_objects_by_name: &HashMap<String, &Json>,
) -> String {
    if let Literal::Hash(_) = value {
        return literal_hash_rhs(value, target_type.unwrap_or(""), value_objects_by_name);
    }
    if let Some(target_type) = target_type {
        if value_objects_by_name.contains_key(target_type) {
            if let Some(sole) = crate::json_codec::sole_field_of(target_type, value_objects_by_name)
            {
                return literal_hash_rhs(
                    &Literal::Hash(vec![(sole, value.clone())]),
                    target_type,
                    value_objects_by_name,
                );
            }
        }
    }
    crate::literal::literal_rhs(value)
}

/// True when a literal Hash fills an ordinary value object or matches one closed-set member row.
pub fn literal_hash_bridgeable(
    hash: &Literal,
    target_type: &str,
    value_objects_by_name: &HashMap<String, &Json>,
) -> bool {
    let Some(vo) = value_objects_by_name.get(target_type) else {
        return false;
    };

    if vo.get("closed_set").is_some_and(Json::as_bool) {
        let members = vo.get("members").map_or_default(Json::each);
        members
            .iter()
            .any(|member| member_matches_hash(member, hash))
    } else {
        let attrs = vo.get("attributes").map_or_default(Json::each);
        attrs
            .iter()
            .all(|attr| hash.get(crate::attr::name(attr)).is_some())
    }
}

/// True when every field/value pair in a closed-set member row equals the Hash's value at that
/// key, compared textually.
fn member_matches_hash(member: &Json, hash: &Literal) -> bool {
    let pairs = member.as_array().unwrap_or(&[]);
    pairs.iter().all(|pair| {
        let kv = pair.as_array().unwrap_or(&[]);
        let (Some(field), Some(value)) = (kv.first().and_then(Json::as_str), kv.get(1)) else {
            return false;
        };
        hash.get(field)
            .is_some_and(|held| literal_to_s(held) == value.to_s())
    })
}

/// A `Literal` rendered as Ruby's `#to_s`, for the textual member-row comparison.
fn literal_to_s(lit: &Literal) -> String {
    match lit {
        Literal::Nil => String::new(),
        Literal::Bool(b) => b.to_string(),
        Literal::Int(n) => n.to_string(),
        Literal::Float(n) => format!("{n}"),
        Literal::Symbol(s) => s.clone(),
        Literal::Str(s) => s.clone(),
        Literal::Hash(_) | Literal::Array(_) => String::new(),
    }
}

#[allow(
    clippy::panic,
    reason = "a drifted exemplar or invalid IR aborts generation on purpose"
)]
pub fn literal_hash_rhs(
    hash: &Literal,
    target_type: &str,
    value_objects_by_name: &HashMap<String, &Json>,
) -> String {
    let vo = value_objects_by_name
        .get(target_type)
        .unwrap_or_else(|| panic!("unsupported literal hash source {hash:?} -> {target_type} — literal_hash_bridgeable? should have caught this"));

    if vo.get("closed_set").is_some_and(Json::as_bool) {
        let members = vo.get("members").map_or_default(Json::each);
        let row = members
            .iter()
            .find(|member| member_matches_hash(member, hash))
            .unwrap_or_else(|| panic!("literal {hash:?} matches no member of {target_type} — literal_hash_bridgeable? should have caught this"));
        format!(
            "{}::{}",
            naming::rust_ident(target_type),
            closed_set_variant_of_row(row)
        )
    } else {
        let attrs = vo.get("attributes").map_or_default(Json::each);
        let fields: Vec<String> = attrs
            .iter()
            .map(|attr| {
                let name = crate::attr::name(attr);
                let value = hash
                    .get(name)
                    .unwrap_or_else(|| panic!("literal {hash:?} missing field {name} for {target_type} — literal_hash_bridgeable? should have caught this"));
                format!("{}: {}", naming::rust_ident_field(name), crate::literal::literal_rhs(value))
            })
            .collect();
        format!(
            "{} {{ {} }}",
            naming::rust_ident(target_type),
            fields.join(", ")
        )
    }
}

fn closed_set_variant_of_row(row: &Json) -> String {
    let pairs = row.as_array().unwrap_or(&[]);
    let first = pairs.first().and_then(Json::as_array).unwrap_or(&[]);
    let value = first.get(1).map(Json::to_s).unwrap_or_default();
    naming::closed_set_variant(&value)
}

pub fn integer_field_of(vo: Option<&Json>) -> Option<String> {
    scalar_field_of(vo, "Integer")
}

fn scalar_field_of(vo: Option<&Json>, type_name: &str) -> Option<String> {
    let vo = vo?;
    if vo.get("closed_set").is_some_and(Json::as_bool) {
        return None;
    }
    let attrs = vo.get("attributes").map_or_default(Json::each);
    attrs
        .iter()
        .find(|a| crate::attr::type_name(a) == type_name)
        .map(|a| crate::attr::name(a).to_string())
}

/// Which machine number a value object's arithmetic field is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NumericKind {
    Integer,
    Float,
}

/// The field arithmetic acts on: the first Integer field, else the first Float field.
pub fn numeric_field_of(vo: Option<&Json>) -> Option<(String, NumericKind)> {
    integer_field_of(vo)
        .map(|field| (field, NumericKind::Integer))
        .or_else(|| scalar_field_of(vo, "Float").map(|field| (field, NumericKind::Float)))
}

fn target_attribute<'a>(mutation: &Json, aggregate: &'a Json) -> Option<&'a Json> {
    let target = mutation.get("target").map(Json::to_s).unwrap_or_default();
    let attrs = aggregate.get("attributes").map_or_default(Json::each);
    let target_attr = attrs.iter().find(|a| crate::attr::name(a) == target)?;
    if crate::attr::list(target_attr) {
        return None;
    }
    Some(target_attr)
}

/// The target half of an `:increment`/`:decrement`/`:multiply` mutation.
pub fn arithmetic_target_field<'a>(
    mutation: &Json,
    aggregate: &'a Json,
    value_objects_by_name: &HashMap<String, &Json>,
) -> Option<(&'a Json, String, NumericKind)> {
    let target_attr = target_attribute(mutation, aggregate)?;
    let (field, kind) = numeric_field_of(
        value_objects_by_name
            .get(crate::attr::type_name(target_attr))
            .copied(),
    )?;
    Some((target_attr, field, kind))
}

/// The target of a `:clamp`, whose bounds are integers: Integer-field value objects only.
pub fn integer_target_field<'a>(
    mutation: &Json,
    aggregate: &'a Json,
    value_objects_by_name: &HashMap<String, &Json>,
) -> Option<(&'a Json, String)> {
    let target_attr = target_attribute(mutation, aggregate)?;
    let field = integer_field_of(
        value_objects_by_name
            .get(crate::attr::type_name(target_attr))
            .copied(),
    )?;
    Some((target_attr, field))
}

/// The amount half — resolved to a raw Rust expression of the target field's own type.
pub fn arithmetic_amount_expr(
    source: &Json,
    command: &Json,
    value_objects_by_name: &HashMap<String, &Json>,
    target_field: &str,
    kind: NumericKind,
) -> Option<String> {
    match kind {
        NumericKind::Integer => {
            integer_amount_expr(source, command, value_objects_by_name, target_field)
        }
        NumericKind::Float => float_amount_expr(source, command, value_objects_by_name),
    }
}

fn integer_amount_expr(
    source: &Json,
    command: &Json,
    value_objects_by_name: &HashMap<String, &Json>,
    target_integer_field: &str,
) -> Option<String> {
    let kind = source.get("kind").map(Json::to_s).unwrap_or_default();
    if kind == "literal" {
        let value = source.get("value")?;
        if matches!(value.number(), Some(Number::Int(_))) {
            return Some(naming::literal_rhs(value));
        }
        if !matches!(value, Json::Object(_)) {
            return None;
        }
        let key_value = value.get_raw(target_integer_field)?;
        return match key_value.number() {
            Some(Number::Int(_)) => Some(naming::literal_rhs(key_value)),
            _ => None,
        };
    }
    if kind == "argument" {
        let name = source.get("name").map(Json::to_s).unwrap_or_default();
        let attrs = command.get("attributes").map_or_default(Json::each);
        let arg_attr = attrs.iter().find(|a| crate::attr::name(a) == name)?;
        if crate::attr::type_name(arg_attr) == "Integer" {
            return Some(format!(
                "args.{}",
                naming::rust_ident_field(crate::attr::name(arg_attr))
            ));
        }
        let field = integer_field_of(
            value_objects_by_name
                .get(crate::attr::type_name(arg_attr))
                .copied(),
        )?;
        return Some(format!(
            "args.{}.{}",
            naming::rust_ident_field(crate::attr::name(arg_attr)),
            naming::rust_ident_field(&field)
        ));
    }
    None
}

// A Float target takes a Float or Integer amount, an Integer widened to `f64` as Ruby coerces it.
fn float_amount_expr(
    source: &Json,
    command: &Json,
    value_objects_by_name: &HashMap<String, &Json>,
) -> Option<String> {
    let kind = source.get("kind").map(Json::to_s).unwrap_or_default();
    if kind == "literal" {
        let value = source.get("value")?;
        return match value.number()? {
            Number::Int(n) => Some(format!("({n} as f64)")),
            Number::Float(_) => Some(naming::literal_rhs(value)),
        };
    }
    if kind != "argument" {
        return None;
    }
    let name = source.get("name").map(Json::to_s).unwrap_or_default();
    let attrs = command.get("attributes").map_or_default(Json::each);
    let arg_attr = attrs.iter().find(|a| crate::attr::name(a) == name)?;
    let arg = format!(
        "args.{}",
        naming::rust_ident_field(crate::attr::name(arg_attr))
    );
    match crate::attr::type_name(arg_attr) {
        "Float" => return Some(arg),
        "Integer" => return Some(format!("({arg} as f64)")),
        _ => {}
    }
    let (field, field_kind) = numeric_field_of(
        value_objects_by_name
            .get(crate::attr::type_name(arg_attr))
            .copied(),
    )?;
    let access = format!("{arg}.{}", naming::rust_ident_field(&field));
    Some(match field_kind {
        NumericKind::Float => access,
        NumericKind::Integer => format!("({access} as f64)"),
    })
}

/// `clamp:` bounds as `[min, max]` integers; `None` for anything else.
pub fn clamp_bounds_ints(source: &Json) -> Option<(i64, i64)> {
    if source.get("kind").map(Json::to_s).unwrap_or_default() != "literal" {
        return None;
    }
    let value = source.get("value")?;
    let items = value.as_array()?;
    if items.len() != 2 {
        return None;
    }
    let Some(Number::Int(min)) = items[0].number() else {
        return None;
    };
    let Some(Number::Int(max)) = items[1].number() else {
        return None;
    };
    Some((min, max))
}

/// An aggregate attribute a creating command's arguments never mention.
#[allow(
    clippy::unwrap_used,
    reason = "the value was checked just before; None would mean invalid IR"
)]
pub fn creation_default_rhs(
    attr: &Json,
    value_objects_by_name: &HashMap<String, &Json>,
) -> Option<String> {
    if let Some(default) = crate::attr::default(attr) {
        return Some(if let Json::Object(_) = default {
            literal_hash_rhs(
                &Literal::from_json(default),
                crate::attr::type_name(attr),
                value_objects_by_name,
            )
        } else {
            naming::literal_rhs(default)
        });
    }

    let vo = value_objects_by_name.get(crate::attr::type_name(attr))?;
    if vo.get("closed_set").is_some_and(Json::as_bool) {
        return None;
    }
    let attrs = vo.get("attributes").map_or_default(Json::each);
    // Vacuously true on an empty list, as Ruby's `all?`; only a present field without a default
    // fails.
    if !attrs.iter().all(|f| crate::attr::default(f).is_some()) {
        return None;
    }
    let fields: Vec<String> = attrs
        .iter()
        .map(|f| {
            format!(
                "{}: {}",
                naming::rust_ident_field(crate::attr::name(f)),
                naming::literal_rhs(crate::attr::default(f).unwrap())
            )
        })
        .collect();
    Some(format!(
        "{} {{ {} }}",
        naming::rust_ident(crate::attr::type_name(attr)),
        fields.join(", ")
    ))
}

/// The `corrects "EventName"` mutation, if this command declares one.
pub fn corrects_of(command: &Json) -> Option<&Json> {
    command
        .get("mutations")
        .map_or_default(Json::each)
        .iter()
        .find(|m| m.get("op").map(Json::to_s).unwrap_or_default() == "corrects")
}

/// True when a `corrects` mutation carries `reverses: true`.
/// The derivation runs in Ruby; only a command whose mutations are still just `corrects` is
/// refused.
pub fn corrects_reverses(mutation: &Json) -> bool {
    mutation
        .get("source")
        .and_then(|s| s.get("value"))
        .and_then(|v| v.get("reverses"))
        .is_some_and(Json::as_bool)
}

/// Synthetic flag field name, e.g. `emitted_fee_applied` from `"FeeApplied"`; must match Ruby's.
pub fn corrects_flag_field(event_name: &str) -> String {
    let mut out = String::from("emitted_");
    let chars: Vec<char> = event_name.chars().collect();
    for (i, &c) in chars.iter().enumerate() {
        if c.is_ascii_uppercase() && i > 0 {
            let prev = chars[i - 1];
            if prev.is_ascii_lowercase() || prev.is_ascii_digit() {
                out.push('_');
            }
        }
        out.push(c.to_ascii_lowercase());
    }
    out
}

/// Every event name any command on this aggregate, entities included, names in a `corrects`
/// mutation. The flag field lives on the parent record whichever level declares it.
pub fn correctable_event_names(aggregate: &Json) -> Vec<String> {
    let mut names = corrects_targets_of(aggregate.get("commands").map_or_default(Json::each));
    for entity in aggregate.get("entities").map_or_default(Json::each) {
        for name in entity_correctable_event_names(entity) {
            if !names.contains(&name) {
                names.push(name);
            }
        }
    }
    names
}

/// The entity-recursive half of `correctable_event_names`.
fn entity_correctable_event_names(entity: &Json) -> Vec<String> {
    let mut names = corrects_targets_of(entity.get("commands").map_or_default(Json::each));
    for nested in entity.get("entities").map_or_default(Json::each) {
        for name in entity_correctable_event_names(nested) {
            if !names.contains(&name) {
                names.push(name);
            }
        }
    }
    names
}

fn corrects_targets_of(commands: &[Json]) -> Vec<String> {
    let mut names: Vec<String> = Vec::new();
    for c in commands {
        for m in c.get("mutations").map_or_default(Json::each) {
            if m.get("op").map(Json::to_s).unwrap_or_default() == "corrects" {
                let name = m.get("target").map(Json::to_s).unwrap_or_default();
                if !names.contains(&name) {
                    names.push(name);
                }
            }
        }
    }
    names
}

/// The synthetic `GivenSpec` prepended to a `corrects`-declaring command.
pub fn corrects_given_specs(command: &Json) -> Vec<String> {
    let Some(corrects) = corrects_of(command) else {
        return Vec::new();
    };
    let event_name = corrects.get("target").map(Json::to_s).unwrap_or_default();
    vec![format!(
        "            crate::kernel::GivenSpec {{ description: \"\", expr: crate::kernel::Expr::Lookup({:?}), corrects_event: Some({:?}) }},",
        corrects_flag_field(&event_name),
        event_name
    )]
}

#[cfg(test)]
mod float_arithmetic_tests {
    use super::*;

    fn vos() -> Vec<Json> {
        ["Count:Integer", "Weight:Float", "Label:String"]
            .iter()
            .map(|pair| {
                let (name, ty) = pair.split_once(':').unwrap();
                Json::parse(&format!(
                    r#"{{"name":"{name}","attributes":[{{"name":"value","type":"{ty}","list":false}}]}}"#
                ))
                .unwrap()
            })
            .collect()
    }

    fn by_name(vos: &[Json]) -> HashMap<String, &Json> {
        vos.iter()
            .map(|vo| (vo.get("name").map(Json::to_s).unwrap_or_default(), vo))
            .collect()
    }

    fn aggregate() -> Json {
        Json::parse(r#"{"attributes":[{"name":"weight","type":"Weight","list":false},{"name":"count","type":"Count","list":false},{"name":"label","type":"Label","list":false}]}"#).unwrap()
    }

    fn command() -> Json {
        Json::parse(r#"{"attributes":[{"name":"more","type":"Weight"},{"name":"n","type":"Integer"},{"name":"f","type":"Float"},{"name":"c","type":"Count"}]}"#).unwrap()
    }

    fn mutation(target: &str) -> Json {
        Json::parse(&format!(r#"{{"target":"{target}","op":"increment"}}"#)).unwrap()
    }

    fn amount(source: &str, kind: NumericKind) -> Option<String> {
        let vos = vos();
        arithmetic_amount_expr(
            &Json::parse(source).unwrap(),
            &command(),
            &by_name(&vos),
            "value",
            kind,
        )
    }

    #[test]
    fn a_float_field_value_object_is_a_float_target() {
        let vos = vos();
        let aggregate = aggregate();
        let (_, field, kind) =
            arithmetic_target_field(&mutation("weight"), &aggregate, &by_name(&vos)).unwrap();
        assert_eq!((field.as_str(), kind), ("value", NumericKind::Float));
    }

    #[test]
    fn an_integer_field_value_object_stays_an_integer_target() {
        let vos = vos();
        let aggregate = aggregate();
        let (_, _, kind) =
            arithmetic_target_field(&mutation("count"), &aggregate, &by_name(&vos)).unwrap();
        assert_eq!(kind, NumericKind::Integer);
    }

    #[test]
    fn a_text_field_value_object_is_no_arithmetic_target() {
        let vos = vos();
        let aggregate = aggregate();
        assert!(arithmetic_target_field(&mutation("label"), &aggregate, &by_name(&vos)).is_none());
    }

    #[test]
    fn clamp_still_takes_only_integer_targets() {
        let vos = vos();
        let aggregate = aggregate();
        assert!(integer_target_field(&mutation("weight"), &aggregate, &by_name(&vos)).is_none());
        assert!(integer_target_field(&mutation("count"), &aggregate, &by_name(&vos)).is_some());
    }

    #[test]
    fn a_float_target_reads_a_float_value_object_argument() {
        let source = r#"{"kind":"argument","name":"more"}"#;
        assert_eq!(
            amount(source, NumericKind::Float).as_deref(),
            Some("args.more.value")
        );
    }

    #[test]
    fn a_float_target_widens_an_integer_argument_and_integer_value_object() {
        assert_eq!(
            amount(r#"{"kind":"argument","name":"n"}"#, NumericKind::Float).as_deref(),
            Some("(args.n as f64)")
        );
        assert_eq!(
            amount(r#"{"kind":"argument","name":"c"}"#, NumericKind::Float).as_deref(),
            Some("(args.c.value as f64)")
        );
    }

    #[test]
    fn a_float_target_takes_float_and_integer_literals() {
        assert_eq!(
            amount(r#"{"kind":"literal","value":2.5}"#, NumericKind::Float).as_deref(),
            Some("2.5")
        );
        assert_eq!(
            amount(r#"{"kind":"literal","value":3}"#, NumericKind::Float).as_deref(),
            Some("(3 as f64)")
        );
    }

    #[test]
    fn an_integer_target_still_refuses_a_float_literal() {
        assert!(amount(r#"{"kind":"literal","value":2.5}"#, NumericKind::Integer).is_none());
    }
}
