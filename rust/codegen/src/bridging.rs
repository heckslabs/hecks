//! Port of `rust/project/bridging.rb` — the cross-type coercion checks
//! shared by `:set`'s RHS and `:append`'s per-field RHS. Mirrors the Ruby
//! source directly; read that file's own header comments for the "why"
//! behind each shape.

use crate::json::Json;
use crate::literal::Literal;
use crate::naming;
use std::collections::{HashMap, HashSet};

/// `use crate::generated::<mod_name>::<owner>::<Type>;` for every value
/// object THIS aggregate's own commands/entity-commands/port operations
/// reference by NAME but never declare locally — see `domain_generator.rb`'s
/// own header on `domain_value_object_owner`/`cross_aggregate_vo_imports`
/// for the full argument (`SafeDepositBox.Rent`'s own `attribute :customer,
/// CustomerNumber` — `Customer`'s own VO — is the corpus's one live
/// example). A type name that's ALSO declared LOCALLY is never foreign, no
/// matter what `domain_value_object_owner` says — the local declaration
/// always wins.
pub fn cross_aggregate_vo_imports(aggregate: &Json, domain_value_object_owner: &HashMap<String, String>, mod_name: &str) -> Vec<String> {
    let local_names: HashSet<String> = aggregate.get("value_objects").map(Json::each).unwrap_or(&[]).iter().map(|vo| vo.get("name").and_then(Json::as_str).unwrap_or("").to_string()).collect();

    let commands = aggregate.get("commands").map(Json::each).unwrap_or(&[]);
    let entity_commands = aggregate.get("entities").map(Json::each).unwrap_or(&[]).iter().flat_map(|e| e.get("commands").map(Json::each).unwrap_or(&[]).iter());
    let port_operations = aggregate.get("ports").map(Json::each).unwrap_or(&[]).iter().flat_map(|p| p.get("operations").map(Json::each).unwrap_or(&[]).iter());

    let mut foreign_types: Vec<String> = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    for c in commands.iter().chain(entity_commands).chain(port_operations) {
        for attr in c.get("attributes").map(Json::each).unwrap_or(&[]) {
            let type_name = crate::attr::type_name(attr).to_string();
            if local_names.contains(&type_name) || seen.contains(&type_name) {
                continue;
            }
            seen.insert(type_name.clone());
            foreign_types.push(type_name);
        }
    }

    let mut pairs: Vec<(String, String)> = foreign_types.into_iter().filter_map(|type_name| domain_value_object_owner.get(&type_name).map(|owner| (type_name, owner.clone()))).collect();
    pairs.sort_by(|(a_type, a_owner), (b_type, b_owner)| (a_owner, a_type).cmp(&(b_owner, b_type)));
    pairs.into_iter().map(|(type_name, owner)| format!("use crate::generated::{mod_name}::{}::{};", owner.to_lowercase(), naming::rust_ident(&type_name))).collect()
}

/// `vo_field_bridgeable?` — `Value::Coercion#fields_for`, read directly: a
/// value object rebuilds into any differently-named target value object
/// that shares its field NAMES, matched by name, with the target's own
/// `default:` filling anything the source doesn't carry.
pub fn vo_field_bridgeable(source_vo: Option<&Json>, target_vo: Option<&Json>) -> bool {
    let (Some(source_vo), Some(target_vo)) = (source_vo, target_vo) else { return false };
    if source_vo.get("closed_set").map(Json::as_bool).unwrap_or(false) || target_vo.get("closed_set").map(Json::as_bool).unwrap_or(false) {
        return closed_set_bridge_members(source_vo, target_vo).is_some();
    }

    let source_attrs = source_vo.get("attributes").map(Json::each).unwrap_or(&[]);
    let target_attrs = target_vo.get("attributes").map(Json::each).unwrap_or(&[]);
    target_attrs.iter().all(|t_attr| {
        let t_name = crate::attr::name(t_attr);
        source_attrs.iter().any(|s_attr| crate::attr::name(s_attr) == t_name) || crate::attr::default(t_attr).is_some()
    })
}

/// Port of bridging.rb's `closed_set_bridge_members` — one closed set
/// into another, admitted only when every source member is a target
/// member (both single-field), so the bridge is an infallible `match`.
fn closed_set_bridge_members<'a>(source_vo: &'a Json, target_vo: &Json) -> Option<&'a [Json]> {
    let closed = |vo: &Json| vo.get("closed_set").map(Json::as_bool).unwrap_or(false);
    if !closed(source_vo) || !closed(target_vo) {
        return None;
    }
    let single = |vo: &Json| vo.get("attributes").map(Json::each).unwrap_or(&[]).len() == 1;
    if !single(source_vo) || !single(target_vo) {
        return None;
    }
    let target_values: Vec<String> = target_vo.get("members").map(Json::each).unwrap_or(&[]).iter().map(closed_set_row_value).collect();
    let source_rows = source_vo.get("members").map(Json::each).unwrap_or(&[]);
    if source_rows.iter().all(|row| target_values.contains(&closed_set_row_value(row))) {
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

pub fn vo_field_rhs(source_expr: &str, source_vo: &Json, target_type: &str, value_objects_by_name: &HashMap<String, &Json>) -> String {
    let target_vo = value_objects_by_name[target_type];
    if let Some(rows) = closed_set_bridge_members(source_vo, target_vo) {
        let source_type = source_vo.get("name").map(Json::to_s).unwrap_or_default();
        let arms: Vec<String> = rows
            .iter()
            .map(|row| format!("{}::{} => {}::{}", naming::rust_ident(&source_type), closed_set_variant_of_row(row), naming::rust_ident(target_type), closed_set_variant_of_row(row)))
            .collect();
        return format!("match &{source_expr} {{ {} }}", arms.join(", "));
    }
    let source_attrs = source_vo.get("attributes").map(Json::each).unwrap_or(&[]);
    let target_attrs = target_vo.get("attributes").map(Json::each).unwrap_or(&[]);

    let fields: Vec<String> = target_attrs
        .iter()
        .map(|t_attr| {
            let field = naming::rust_ident_field(crate::attr::name(t_attr));
            let t_name = crate::attr::name(t_attr);
            if source_attrs.iter().any(|s_attr| crate::attr::name(s_attr) == t_name) {
                format!("{field}: {source_expr}.{field}.clone()")
            } else {
                format!("{field}: {}", naming::literal_rhs(crate::attr::default(t_attr).unwrap()))
            }
        })
        .collect();
    format!("{} {{ {} }}", naming::rust_ident(target_type), fields.join(", "))
}

/// `bridgeable_value_types?` — shared by BOTH `:set`'s own RHS and
/// `:append`'s per-field RHS.
pub fn bridgeable_value_types(source_type: &str, target_type: &str, value_objects_by_name: &HashMap<String, &Json>) -> bool {
    if source_type == target_type {
        return true;
    }
    if let (Some(s), Some(t)) = (naming::effective_scalar_type(source_type), naming::effective_scalar_type(target_type)) {
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
            let closed = vo.get("closed_set").map(Json::as_bool).unwrap_or(false);
            let attrs = vo.get("attributes").map(Json::each).unwrap_or(&[]);
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

pub fn value_rhs(source_expr: &str, source_type: &str, target_type: &str, value_objects_by_name: &HashMap<String, &Json>) -> String {
    if source_type == target_type {
        return format!("{source_expr}.clone()");
    }
    if let (Some(s), Some(t)) = (naming::effective_scalar_type(source_type), naming::effective_scalar_type(target_type)) {
        if s == t {
            return format!("{source_expr}.clone()");
        }
    }

    let source_vo = value_objects_by_name.get(source_type).copied();
    let target_vo = value_objects_by_name.get(target_type).copied();
    if target_vo.is_some() {
        return vo_field_rhs(source_expr, source_vo.expect("bridgeable_value_types? should have caught this"), target_type, value_objects_by_name);
    }

    let source_vo = source_vo.unwrap_or_else(|| panic!("unsupported coercion {source_type} -> {target_type} — bridgeable_value_types? should have caught this"));
    let attrs = source_vo.get("attributes").map(Json::each).unwrap_or(&[]);
    if source_vo.get("closed_set").map(Json::as_bool).unwrap_or(false) || attrs.len() != 1 {
        panic!("unsupported coercion {source_type} -> {target_type} — bridgeable_value_types? should have caught this");
    }
    format!("{source_expr}.{}.clone()", naming::rust_ident_field(crate::attr::name(&attrs[0])))
}

pub fn literal_set_bridgeable(value: &Literal, target_type: Option<&str>, value_objects_by_name: &HashMap<String, &Json>) -> bool {
    match value {
        Literal::Hash(_) => match target_type {
            Some(target_type) => literal_hash_bridgeable(value, target_type, value_objects_by_name),
            None => false,
        },
        Literal::Str(_) | Literal::Int(_) | Literal::Float(_) | Literal::Bool(_) => {
            let Some(target_type) = target_type else { return true };
            if !value_objects_by_name.contains_key(target_type) {
                return true;
            }
            // A SCALAR literal into a SINGLE-FIELD value object — see
            // bridging.rb's own `literal_set_bridgeable?`: the literal is
            // the sole field's value and bridges as the hash it stands for.
            match crate::json_codec::sole_field_of(target_type, value_objects_by_name) {
                Some(sole) => literal_hash_bridgeable(&Literal::Hash(vec![(sole, value.clone())]), target_type, value_objects_by_name),
                None => false,
            }
        }
        _ => false,
    }
}

/// Port of bridging.rb's `literal_rhs_for` — the rendered right-hand
/// side of ANY literal into a target type.
pub fn literal_rhs_for(value: &Literal, target_type: Option<&str>, value_objects_by_name: &HashMap<String, &Json>) -> String {
    if let Literal::Hash(_) = value {
        return literal_hash_rhs(value, target_type.unwrap_or(""), value_objects_by_name);
    }
    if let Some(target_type) = target_type {
        if value_objects_by_name.contains_key(target_type) {
            if let Some(sole) = crate::json_codec::sole_field_of(target_type, value_objects_by_name) {
                return literal_hash_rhs(&Literal::Hash(vec![(sole, value.clone())]), target_type, value_objects_by_name);
            }
        }
    }
    crate::literal::literal_rhs(value)
}

/// A literal Hash's own bridgeability into a target type — either an
/// ordinary VO (every declared field present) or a CLOSED SET (the Hash
/// matches one member row's own fields exactly).
pub fn literal_hash_bridgeable(hash: &Literal, target_type: &str, value_objects_by_name: &HashMap<String, &Json>) -> bool {
    let Some(vo) = value_objects_by_name.get(target_type) else { return false };

    if vo.get("closed_set").map(Json::as_bool).unwrap_or(false) {
        let members = vo.get("members").map(Json::each).unwrap_or(&[]);
        members.iter().any(|member| member_matches_hash(member, hash))
    } else {
        let attrs = vo.get("attributes").map(Json::each).unwrap_or(&[]);
        attrs.iter().all(|attr| hash.get(crate::attr::name(attr)).is_some())
    }
}

/// A closed-set `members` row (`[[field, value], ...]`) matched against a
/// literal Hash — every field/value pair in the row must equal the Hash's
/// own value at that key. Ruby compares against BOTH a Symbol and String
/// key form of the hash (`[hash[field.to_sym], hash[field.to_s]].include?
/// (value)`) — moot here since `Literal::Hash`'s own keys are always plain
/// Rust `String`s already (there is no separate Symbol-keyed lookup to
/// fall back to), and compares the row's own value (always a JSON scalar
/// string off `ir.json`, read via `Json::to_s`) against the Hash's OWN
/// value textually, since a member row's field value has no richer type
/// than a String to compare against.
fn member_matches_hash(member: &Json, hash: &Literal) -> bool {
    let pairs = member.as_array().unwrap_or(&[]);
    pairs.iter().all(|pair| {
        let kv = pair.as_array().unwrap_or(&[]);
        let (Some(field), Some(value)) = (kv.first().and_then(Json::as_str), kv.get(1)) else { return false };
        match hash.get(field) {
            Some(held) => literal_to_s(held) == value.to_s(),
            None => false,
        }
    })
}

/// A `Literal`'s own `#to_s` — used only for the member-row textual
/// comparison above, where Ruby compares a Hash's raw (never `.inspect`'d)
/// value against a member row's own String field via `==`, and both sides
/// are ultimately plain Ruby scalars whose `==` degrades to string/number
/// equality once both are compared against a `Json::to_s`'d row value.
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

pub fn literal_hash_rhs(hash: &Literal, target_type: &str, value_objects_by_name: &HashMap<String, &Json>) -> String {
    let vo = value_objects_by_name
        .get(target_type)
        .unwrap_or_else(|| panic!("unsupported literal hash source {hash:?} -> {target_type} — literal_hash_bridgeable? should have caught this"));

    if vo.get("closed_set").map(Json::as_bool).unwrap_or(false) {
        let members = vo.get("members").map(Json::each).unwrap_or(&[]);
        let row = members
            .iter()
            .find(|member| member_matches_hash(member, hash))
            .unwrap_or_else(|| panic!("literal {hash:?} matches no member of {target_type} — literal_hash_bridgeable? should have caught this"));
        format!("{}::{}", naming::rust_ident(target_type), closed_set_variant_of_row(row))
    } else {
        let attrs = vo.get("attributes").map(Json::each).unwrap_or(&[]);
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
        format!("{} {{ {} }}", naming::rust_ident(target_type), fields.join(", "))
    }
}

fn closed_set_variant_of_row(row: &Json) -> String {
    let pairs = row.as_array().unwrap_or(&[]);
    let first = pairs.first().and_then(Json::as_array).unwrap_or(&[]);
    let value = first.get(1).map(Json::to_s).unwrap_or_default();
    naming::closed_set_variant(&value)
}

pub fn integer_field_of(vo: Option<&Json>) -> Option<String> {
    let vo = vo?;
    if vo.get("closed_set").map(Json::as_bool).unwrap_or(false) {
        return None;
    }
    let attrs = vo.get("attributes").map(Json::each).unwrap_or(&[]);
    attrs.iter().find(|a| crate::attr::type_name(a) == "Integer").map(|a| crate::attr::name(a).to_string())
}

/// The target half of an `:increment`/`:decrement` mutation.
pub fn arithmetic_target_field<'a>(mutation: &Json, aggregate: &'a Json, value_objects_by_name: &HashMap<String, &Json>) -> Option<(&'a Json, String)> {
    let target = mutation.get("target").map(Json::to_s).unwrap_or_default();
    let attrs = aggregate.get("attributes").map(Json::each).unwrap_or(&[]);
    let target_attr = attrs.iter().find(|a| crate::attr::name(a) == target)?;
    if crate::attr::list(target_attr) {
        return None;
    }
    let field = integer_field_of(value_objects_by_name.get(crate::attr::type_name(target_attr)).copied())?;
    Some((target_attr, field))
}

/// The amount half — resolved to a raw Rust integer-typed EXPRESSION.
pub fn arithmetic_amount_expr(source: &Json, command: &Json, value_objects_by_name: &HashMap<String, &Json>, target_integer_field: &str) -> Option<String> {
    let kind = source.get("kind").map(Json::to_s).unwrap_or_default();
    if kind == "literal" {
        let value = source.get("value")?;
        if let Json::Int(_) = value {
            return Some(naming::literal_rhs(value));
        }
        if !matches!(value, Json::Object(_)) {
            return None;
        }
        let key_value = value.get_raw(target_integer_field)?;
        return match key_value {
            Json::Int(_) => Some(naming::literal_rhs(key_value)),
            _ => None,
        };
    }
    if kind == "argument" {
        let name = source.get("name").map(Json::to_s).unwrap_or_default();
        let attrs = command.get("attributes").map(Json::each).unwrap_or(&[]);
        let arg_attr = attrs.iter().find(|a| crate::attr::name(a) == name)?;
        if crate::attr::type_name(arg_attr) == "Integer" {
            return Some(format!("args.{}", naming::rust_ident_field(crate::attr::name(arg_attr))));
        }
        let field = integer_field_of(value_objects_by_name.get(crate::attr::type_name(arg_attr)).copied())?;
        return Some(format!("args.{}.{}", naming::rust_ident_field(crate::attr::name(arg_attr)), naming::rust_ident_field(&field)));
    }
    None
}

/// An aggregate attribute a CREATING command's own arguments never
/// mention — `Runtime::Instance.defaults`/`.default_for`, read directly.
pub fn creation_default_rhs(attr: &Json, value_objects_by_name: &HashMap<String, &Json>) -> Option<String> {
    if let Some(default) = crate::attr::default(attr) {
        return Some(if let Json::Object(_) = default {
            literal_hash_rhs(&Literal::from_json(default), crate::attr::type_name(attr), value_objects_by_name)
        } else {
            naming::literal_rhs(default)
        });
    }

    let vo = value_objects_by_name.get(crate::attr::type_name(attr))?;
    if vo.get("closed_set").map(Json::as_bool).unwrap_or(false) {
        return None;
    }
    let attrs = vo.get("attributes").map(Json::each).unwrap_or(&[]);
    // Ruby's `all?` on an EMPTY array is vacuously `true` — mirrored here
    // by NOT early-returning on an empty attribute list, only on a
    // genuinely-present field with no default.
    if !attrs.iter().all(|f| crate::attr::default(f).is_some()) {
        return None;
    }
    let fields: Vec<String> = attrs.iter().map(|f| format!("{}: {}", naming::rust_ident_field(crate::attr::name(f)), naming::literal_rhs(crate::attr::default(f).unwrap()))).collect();
    Some(format!("{} {{ {} }}", naming::rust_ident(crate::attr::type_name(attr)), fields.join(", ")))
}
