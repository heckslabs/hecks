//! Type emitters ported from the retired Ruby generator's `types.rb`: records, entities, value objects and
//! closed-set tables.

use crate::exemplar::Exemplar;
use crate::fielded;
use crate::json::Json;
use crate::naming;
use std::collections::HashMap;

pub fn emit_check_invariants(exemplar: &Exemplar, vo: &Json, value_objects_by_name: &HashMap<String, &Json>, aggregates_by_name: &HashMap<String, &Json>) -> String {
    let name = naming::rust_ident(vo.get("name").and_then(Json::as_str).unwrap_or(""));
    let type_name = vo.get("name").and_then(Json::as_str).unwrap_or("").to_string();
    let invariants = vo.get("invariants").map(Json::each).unwrap_or(&[]);

    // The block is flush left to match the Ruby heredoc's dedent; re-indenting it mismatches.
    // Order: nested value objects, then `admits`/`pattern`, then invariants.
    let mut body: Vec<String> = Vec::new();
    let attributes = vo.get("attributes").map(Json::each).unwrap_or(&[]);

    for attr in attributes {
        if naming::effective_scalar_type(crate::attr::type_name(attr)).is_some() {
            continue;
        }
        let is_plain_nested = matches!(value_objects_by_name.get(crate::attr::type_name(attr)), Some(v) if !v.get("closed_set").map(Json::as_bool).unwrap_or(false));
        if !is_plain_nested {
            continue;
        }
        let field = naming::rust_ident_field(crate::attr::name(attr));
        body.push(nested_invariant_line(&field, crate::attr::list(attr), crate::attr::optional(attr)));
    }

    for attr in attributes {
        if crate::attr::list(attr) {
            let field = format!("self.{}", naming::rust_ident_field(crate::attr::name(attr)));
            if let Some(line) = crate::constraints::emit_list_pattern_check(exemplar, &field, attr, &name) {
                body.push(format!("        {line}"));
            }
            continue;
        }
        let field = format!("self.{}", naming::rust_ident_field(crate::attr::name(attr)));
        if let Some(line) = crate::constraints::emit_admits_check(exemplar, &field, attr, aggregates_by_name, value_objects_by_name) {
            body.push(format!("        {line}"));
        }
        if let Some(line) = crate::constraints::emit_pattern_check(exemplar, &field, attr, &name, value_objects_by_name) {
            body.push(format!("        {line}"));
        }
    }

    let invariant_lines: Vec<String> = invariants
        .iter()
        .map(|inv| {
            let ast = inv.get("ast").unwrap_or_else(|| panic!("invariant row has no ast: {inv:?}"));
            let description = inv.get("description").and_then(Json::as_str).unwrap_or("");
            let expr = crate::expr_emitter::emit_ast(ast);
            format!(
                "{{\n    let ctx = crate::kernel::EvalContext {{ args: &crate::kernel::NoFields, instance: self }};\n    if !crate::kernel::interpret(&{expr}, &ctx)?.truthy() {{\n        let mut offered = self.to_json();\n        if let crate::kernel::Json::Object(fields) = &mut offered {{\n            fields.sort_by(|a, b| a.0.cmp(&b.0));\n        }}\n        let offered = offered.to_json_string();\n        return Err(crate::kernel::Refusal::InvariantViolation(crate::kernel::refusal_wording::InvariantViolationValueObjectInvariantArgs {{\n            name: {},\n            description: {},\n            offered: offered.as_str(),\n        }}.render_args()));\n    }}\n}}",
                naming::ruby_inspect_string(&type_name),
                naming::ruby_inspect_string(description),
            )
        })
        .collect();
    body.extend(invariant_lines);

    format!("impl {name} {{\n    pub fn check_invariants(&self) -> Result<(), crate::kernel::Refusal> {{\n{}\n        Ok(())\n    }}\n}}\n", body.join("\n"))
}

/// The line that runs a nested value object's own invariants. An optional slot is an `Option` in
/// the record, so its invariants run only when it is present, as Ruby validates only what it is
/// given; a list's members each run theirs.
fn nested_invariant_line(field: &str, list: bool, optional: bool) -> String {
    match (list, optional) {
        (true, true) => format!("        if let Some(items) = &self.{field} {{ for item in items {{ item.check_invariants()?; }} }}"),
        (true, false) => format!("        for item in &self.{field} {{ item.check_invariants()?; }}"),
        (false, true) => format!("        if let Some(value) = &self.{field} {{ value.check_invariants()?; }}"),
        (false, false) => format!("        self.{field}.check_invariants()?;"),
    }
}

pub fn emit_closed_set_table(exemplar: &Exemplar, vo: &Json) -> String {
    let name = naming::rust_ident(vo.get("name").and_then(Json::as_str).unwrap_or(""));
    let attributes = vo.get("attributes").map(Json::each).unwrap_or(&[]);

    let field_subs_list: Vec<Vec<(&str, String)>> = attributes
        .iter()
        .map(|attr| {
            let mut ty = naming::rust_type(crate::attr::type_name(attr), crate::attr::list(attr));
            if ty == "String" {
                ty = "&'static str".to_string();
            }
            vec![("TmplFieldType", ty), ("tmpl_field", naming::rust_ident_field(crate::attr::name(attr)))]
        })
        .collect();
    let struct_part = exemplar.compose("plain_struct", &[("TmplType", name.clone())], "struct_field", &field_subs_list, "\n");

    let members = vo.get("members").map(Json::each).unwrap_or(&[]);
    let member_literals: Vec<String> = members
        .iter()
        .map(|row| {
            let pairs = row.as_array().unwrap_or(&[]);
            let present: HashMap<String, &Json> = pairs
                .iter()
                .filter_map(|pair| {
                    let kv = pair.as_array()?;
                    let key = kv.first()?.as_str()?.to_string();
                    let val = kv.get(1)?;
                    Some((key, val))
                })
                .collect();

            let fields: Vec<String> = attributes
                .iter()
                .map(|attr| {
                    let field_name = crate::attr::name(attr).to_string();
                    let raw_str: String = match present.get(&field_name) {
                        Some(v) => v.to_s(),
                        None => match crate::attr::default(attr) {
                            Some(d) => d.to_s(),
                            None => String::new(),
                        },
                    };
                    let literal = match crate::attr::type_name(attr) {
                        "Integer" => ruby_to_i(&raw_str).to_string(),
                        "Float" => format!("{}f64", ruby_to_f(&raw_str)),
                        _ => naming::ruby_inspect_string(&raw_str),
                    };
                    exemplar.render("closed_set_table_row_field", &[("tmpl_field", naming::rust_ident_field(&field_name)), ("tmpl_value_placeholder()", literal)])
                })
                .collect();
            format!("    {name} {{ {} }},", fields.join(", "))
        })
        .collect();

    format!("{struct_part}\n\npub const {}: &[{name}] = &[\n{}\n];", naming::screaming_snake(vo.get("name").and_then(Json::as_str).unwrap_or("")), member_literals.join("\n"))
}

/// Ruby's `String#to_i`: parses a leading integer prefix, 0 when there is none.
fn ruby_to_i(s: &str) -> i64 {
    let trimmed = s.trim_start();
    let mut end = 0;
    let bytes = trimmed.as_bytes();
    if end < bytes.len() && (bytes[end] == b'-' || bytes[end] == b'+') {
        end += 1;
    }
    let digits_start = end;
    while end < bytes.len() && bytes[end].is_ascii_digit() {
        end += 1;
    }
    if end == digits_start {
        return 0;
    }
    trimmed[..end].parse().unwrap_or(0)
}

/// Ruby's `String#to_f`: parses a leading float prefix, 0.0 when there is none.
fn ruby_to_f(s: &str) -> f64 {
    let trimmed = s.trim_start();
    let mut end = 0;
    let bytes = trimmed.as_bytes();
    if end < bytes.len() && (bytes[end] == b'-' || bytes[end] == b'+') {
        end += 1;
    }
    let mut seen_digit = false;
    while end < bytes.len() && bytes[end].is_ascii_digit() {
        end += 1;
        seen_digit = true;
    }
    if end < bytes.len() && bytes[end] == b'.' {
        let mut peek = end + 1;
        let mut frac_digit = false;
        while peek < bytes.len() && bytes[peek].is_ascii_digit() {
            peek += 1;
            frac_digit = true;
        }
        if frac_digit {
            end = peek;
            seen_digit = true;
        }
    }
    if !seen_digit {
        return 0.0;
    }
    trimmed[..end].parse().unwrap_or(0.0)
}

pub fn emit_value_object(exemplar: &Exemplar, vo: &Json, value_objects_by_name: &HashMap<String, &Json>, aggregates_by_name: &HashMap<String, &Json>) -> String {
    let name = naming::rust_ident(vo.get("name").and_then(Json::as_str).unwrap_or(""));
    let closed_set = vo.get("closed_set").map(Json::as_bool).unwrap_or(false);
    let attributes = vo.get("attributes").map(Json::each).unwrap_or(&[]);

    if closed_set {
        if attributes.len() > 1 {
            return emit_closed_set_table(exemplar, vo);
        }

        let members = vo.get("members").map(Json::each).unwrap_or(&[]);
        let variants: Vec<String> = members
            .iter()
            .map(|row| {
                let pairs = row.as_array().unwrap_or(&[]);
                let first = pairs.first().and_then(Json::as_array).unwrap_or(&[]);
                let value = first.get(1).map(Json::to_s).unwrap_or_default();
                naming::closed_set_variant(&value)
            })
            .collect();
        let field_subs_list: Vec<Vec<(&str, String)>> = variants.iter().map(|v| vec![("TmplMemberA", v.clone())]).collect();
        let enum_part = exemplar.compose("closed_set_enum", &[("TmplKind", name)], "closed_set_enum:VARIANT", &field_subs_list, "\n");
        return format!("{enum_part}\n\n{}", naming::emit_closed_set_fielded_impl(vo));
    }

    let field_subs_list: Vec<Vec<(&str, String)>> = attributes
        .iter()
        .map(|attr| {
            let mut ty = naming::rust_type(crate::attr::type_name(attr), crate::attr::list(attr));
            if crate::attr::optional(attr) {
                ty = format!("Option<{ty}>");
            }
            vec![("TmplFieldType", ty), ("tmpl_field", naming::rust_ident_field(crate::attr::name(attr)))]
        })
        .collect();
    let struct_part = exemplar.compose("plain_struct", &[("TmplType", name.clone())], "struct_field", &field_subs_list, "\n");

    let fielded_part = fielded::emit_fielded_flat(exemplar, &name, attributes, value_objects_by_name, &[]);
    let invariants_part = emit_check_invariants(exemplar, vo, value_objects_by_name, aggregates_by_name);

    format!("{struct_part}\n\n{fielded_part}\n\n{invariants_part}")
}

/// Attribute type names on `aggregate` that have no Rust mapping.
pub fn unsupported_attribute_types(aggregate: &Json, value_objects_by_name: &HashMap<String, &Json>) -> Vec<String> {
    let entity_names: Vec<&str> = aggregate.get("entities").map(Json::each).unwrap_or(&[]).iter().map(|e| e.get("name").and_then(Json::as_str).unwrap_or("")).collect();
    let mut seen = Vec::new();
    for attr in aggregate.get("attributes").map(Json::each).unwrap_or(&[]) {
        let ty = crate::attr::type_name(attr);
        let supported = naming::effective_scalar_type(ty).is_some() || value_objects_by_name.contains_key(ty) || (crate::attr::list(attr) && entity_names.contains(&ty));
        if !supported && !seen.iter().any(|s| s == ty) {
            seen.push(ty.to_string());
        }
    }
    seen
}

pub fn emit_entity(exemplar: &Exemplar, entity: &Json, value_objects_by_name: &HashMap<String, &Json>) -> String {
    let name = naming::rust_ident(entity.get("name").and_then(Json::as_str).unwrap_or(""));
    let attributes = entity.get("attributes").map(Json::each).unwrap_or(&[]);

    let mut field_subs_list: Vec<Vec<(&str, String)>> = attributes
        .iter()
        .map(|attr| {
            let mut ty = naming::rust_type(crate::attr::type_name(attr), crate::attr::list(attr));
            if crate::attr::optional(attr) {
                ty = format!("Option<{ty}>");
            }
            vec![("TmplFieldType", ty), ("tmpl_field", naming::rust_ident_field(crate::attr::name(attr)))]
        })
        .collect();

    let mut lifecycle_arm: Vec<String> = Vec::new();
    if let Some(lifecycle) = entity.get("lifecycle") {
        let field = lifecycle.get("field").and_then(Json::as_str).unwrap_or("");
        field_subs_list.push(vec![("TmplFieldType", "String".to_string()), ("tmpl_field", naming::rust_ident_field(field))]);
        let ident = naming::rust_ident_field(field);
        lifecycle_arm.push(format!("            \"{field}\" => Some(Field::Value(Value::Str(self.{ident}.clone()))),"));
    }

    let struct_part = exemplar.compose("plain_struct", &[("TmplType", name.clone())], "struct_field", &field_subs_list, "\n");
    let fielded_part = fielded::emit_fielded_flat(exemplar, &name, attributes, value_objects_by_name, &lifecycle_arm);

    format!("{struct_part}\n\n{fielded_part}")
}

pub fn emit_record(exemplar: &Exemplar, aggregate: &Json, value_objects_by_name: &HashMap<String, &Json>) -> String {
    let name = naming::rust_ident(aggregate.get("name").and_then(Json::as_str).unwrap_or(""));
    let attributes = aggregate.get("attributes").map(Json::each).unwrap_or(&[]);

    let mut field_subs_list: Vec<Vec<(&str, String)>> = attributes
        .iter()
        .map(|attr| {
            let list = crate::attr::list(attr);
            let mut ty = naming::rust_type(crate::attr::type_name(attr), list);
            if !list || crate::shared::list_attr_creation_optional(aggregate, crate::attr::name(attr), value_objects_by_name) {
                ty = format!("Option<{ty}>");
            }
            vec![("TmplFieldType", ty), ("tmpl_field", naming::rust_ident_field(crate::attr::name(attr)))]
        })
        .collect();

    if let Some(lifecycle) = aggregate.get("lifecycle") {
        let field = lifecycle.get("field").and_then(Json::as_str).unwrap_or("");
        field_subs_list.push(vec![("TmplFieldType", "String".to_string()), ("tmpl_field", naming::rust_ident_field(field))]);
    }
    for ev in crate::bridging::correctable_event_names(aggregate) {
        field_subs_list.push(vec![("TmplFieldType", "bool".to_string()), ("tmpl_field", crate::bridging::corrects_flag_field(&ev))]);
    }

    let struct_part = exemplar.compose("plain_struct", &[("TmplType", name)], "struct_field", &field_subs_list, "\n");
    let fielded_part = fielded::emit_fielded_record(exemplar, aggregate, value_objects_by_name);

    format!("{struct_part}\n\n{fielded_part}")
}

/// Copy of `ir` whose every `projects` field also carries the `type` of the remote field it reads,
/// so the projecting aggregate's pseudo-attribute and setter follow it (ADR 0025 addendum). A
/// single-field value object resolves to its one attribute's type, a reference to `String`, and a
/// field that resolves to nothing stays `String`.
pub fn with_resolved_projection_types(ir: &Json) -> Json {
    let mut resolved = ir.clone();
    let aggregates: Vec<Json> = ir.get("aggregates").map(Json::each).unwrap_or(&[]).to_vec();
    let Some(list) = resolved.get_mut("aggregates").and_then(Json::as_array_mut) else {
        return resolved;
    };
    for (aggregate, original) in list.iter_mut().zip(aggregates.iter()) {
        let Some(fields) = aggregate.get_mut("projected_fields").and_then(Json::as_array_mut) else {
            continue;
        };
        for field in fields.iter_mut() {
            let scalar = projected_scalar_type(&aggregates, original, field, 0);
            field.set("type", Json::String(scalar));
        }
    }
    resolved
}

const PROJECTION_CHAIN_LIMIT: usize = 8;

// The scalar type a projection of `field` copies, following a chain of projections.
fn projected_scalar_type(aggregates: &[Json], owner: &Json, field: &Json, depth: usize) -> String {
    let reference = field.get("reference").and_then(Json::as_str).unwrap_or("");
    let remote = field.get("remote_field").and_then(Json::as_str).unwrap_or("");
    let target = owner
        .get("attributes")
        .map(Json::each)
        .unwrap_or(&[])
        .iter()
        .find(|a| crate::attr::name(a) == reference)
        .and_then(|a| naming::reference_target(crate::attr::type_name(a)))
        .and_then(|name| aggregates.iter().find(|a| a.get("name").and_then(Json::as_str) == Some(name)));
    target.map(|t| remote_scalar_type(aggregates, t, remote, depth)).unwrap_or_else(|| "String".to_string())
}

fn remote_scalar_type(aggregates: &[Json], target: &Json, remote: &str, depth: usize) -> String {
    let declared = target.get("attributes").map(Json::each).unwrap_or(&[]).iter().find(|a| crate::attr::name(a) == remote);
    if let Some(attr) = declared {
        return unwrapped_scalar_type(target, crate::attr::type_name(attr));
    }
    let chained = target.get("projected_fields").map(Json::each).unwrap_or(&[]).iter().find(|f| f.get("name").and_then(Json::as_str) == Some(remote));
    match chained {
        Some(next) if depth < PROJECTION_CHAIN_LIMIT => projected_scalar_type(aggregates, target, next, depth + 1),
        _ => "String".to_string(),
    }
}

// A single-field value object reads as its one attribute's type; anything else as itself.
fn unwrapped_scalar_type(aggregate: &Json, type_name: &str) -> String {
    let sole = aggregate
        .get("value_objects")
        .map(Json::each)
        .unwrap_or(&[])
        .iter()
        .find(|vo| vo.get("name").and_then(Json::as_str) == Some(type_name))
        .map(|vo| vo.get("attributes").map(Json::each).unwrap_or(&[]))
        .filter(|attrs| attrs.len() == 1 && !crate::attr::list(&attrs[0]))
        .map(|attrs| crate::attr::type_name(&attrs[0]).to_string());
    let resolved = sole.unwrap_or_else(|| type_name.to_string());
    let resolved = if resolved == "Boolean" { "TrueClass".to_string() } else { resolved };
    naming::effective_scalar_type(&resolved).unwrap_or("String").to_string()
}

// The `Value` reader a generated setter narrows with, by scalar type.
fn projection_reader(scalar: &str) -> &'static str {
    match scalar {
        "Integer" => "into_i64",
        "Float" => "into_f64",
        "TrueClass" | "FalseClass" => "into_bool",
        _ => "into_string",
    }
}

/// Port of the retired Ruby generator's `types.rb#projected_field_pseudo_attributes` (ADR 0025).
pub fn projected_field_pseudo_attributes(aggregate: &Json) -> Vec<Json> {
    aggregate
        .get("projected_fields")
        .map(Json::each)
        .unwrap_or(&[])
        .iter()
        .map(|field| {
            let name = field.get("name").and_then(Json::as_str).unwrap_or("").to_string();
            let scalar = field.get("type").and_then(Json::as_str).unwrap_or("String").to_string();
            Json::Object(vec![
                ("name".to_string(), Json::String(name)),
                ("type".to_string(), Json::String(scalar)),
                ("list".to_string(), Json::Bool(false)),
                ("optional".to_string(), Json::Bool(true)),
            ])
        })
        .collect()
}

/// Copy of `aggregate` whose `attributes` also list the projected-field pseudo-attributes, so
/// `emit_record` and `emit_fielded_record` see them (`domain_generator.rb#record_for_struct`).
pub fn with_projected_field_pseudo_attributes(aggregate: &Json) -> Json {
    let mut attributes: Vec<Json> = aggregate.get("attributes").map(Json::each).unwrap_or(&[]).to_vec();
    attributes.extend(projected_field_pseudo_attributes(aggregate));
    let mut pairs: Vec<(String, Json)> = match aggregate {
        Json::Object(pairs) => pairs.iter().filter(|(k, _)| k != "attributes").cloned().collect(),
        _ => Vec::new(),
    };
    pairs.push(("attributes".to_string(), Json::Array(attributes)));
    Json::Object(pairs)
}

/// Port of the retired Ruby generator's `types.rb#emit_set_projected_field`.
pub fn emit_set_projected_field(aggregate: &Json) -> String {
    let name = naming::rust_ident(aggregate.get("name").and_then(Json::as_str).unwrap_or(""));
    let arms: Vec<String> = aggregate
        .get("projected_fields")
        .map(Json::each)
        .unwrap_or(&[])
        .iter()
        .map(|field| {
            let field_name = field.get("name").and_then(Json::as_str).unwrap_or("");
            let ident = naming::rust_ident_field(field_name);
            let reader = projection_reader(field.get("type").and_then(Json::as_str).unwrap_or("String"));
            format!("            {} => self.{} = value.and_then(crate::kernel::Value::{}),", naming::ruby_inspect_string(field_name), ident, reader)
        })
        .collect();
    format!(
        "impl crate::kernel::SetProjectedField for {name} {{\n    fn set_projected_field(&mut self, name: &'static str, value: Option<crate::kernel::Value>) {{\n        match name {{\n{}\n            _ => {{}}\n        }}\n    }}\n}}\n",
        arms.join("\n")
    )
}

/// Port of the retired Ruby generator's `types.rb#emit_projected_field_table`.
pub fn emit_projected_field_table(aggregate: &Json) -> String {
    let name = naming::screaming_snake(aggregate.get("name").and_then(Json::as_str).unwrap_or(""));
    let rows: Vec<String> = aggregate
        .get("projected_fields")
        .map(Json::each)
        .unwrap_or(&[])
        .iter()
        .map(|field| {
            let field_name = field.get("name").and_then(Json::as_str).unwrap_or("");
            let reference = field.get("reference").and_then(Json::as_str).unwrap_or("");
            let remote_field = field.get("remote_field").and_then(Json::as_str).unwrap_or("");
            format!(
                "    crate::kernel::ProjectedFieldSpec {{ field: {}, reference: {}, remote_field: {} }},",
                naming::ruby_inspect_string(field_name),
                naming::ruby_inspect_string(reference),
                naming::ruby_inspect_string(remote_field)
            )
        })
        .collect();
    format!("pub static {name}_PROJECTED_FIELDS: &[crate::kernel::ProjectedFieldSpec] = &[\n{}\n];\n", rows.join("\n"))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A value object with one attribute per Ruby spelling of a boolean.
    fn flag_value_object() -> Json {
        Json::parse(
            r#"{
              "name":"Entry",
              "attributes":[
                {"name":"on","type":"TrueClass","list":false,"optional":false,"default":false},
                {"name":"off","type":"FalseClass","list":false,"optional":false}
              ]
            }"#,
        )
        .unwrap()
    }

    #[test]
    fn boolean_attributes_are_rust_bool_not_a_type_named_for_the_ruby_class() {
        let vo = flag_value_object();
        let generated = emit_value_object(&Exemplar::load(), &vo, &HashMap::new(), &HashMap::new());

        assert!(generated.contains("pub on: bool,"));
        assert!(generated.contains("pub off: bool,"));
        assert!(generated.contains("Value::Bool(self.on)"));
        assert!(!generated.contains("TrueClass,"));
        assert!(!generated.contains("FalseClass,"));
    }

    #[test]
    fn boolean_attributes_round_trip_through_json_as_bool() {
        let vo = flag_value_object();
        let attributes = vo.get("attributes").map(Json::each).unwrap_or(&[]);
        let by_name = HashMap::new();
        let exemplar = Exemplar::load();
        let from_json = crate::json_codec::emit_from_json_flat(&exemplar, "Entry", attributes, &by_name, None, None, false, false, None);
        let to_json = crate::json_codec::emit_to_json_flat(&exemplar, "Entry", attributes, &by_name, false, &[], None);

        assert!(from_json.contains("x.as_bool()"));
        assert!(!from_json.contains("TrueClass::from_json"));
        assert!(to_json.contains("crate::kernel::Json::Bool(self.on)"));
    }

    /// An Event whose `starts_at` is a single-field Integer value object, and a Booking projecting it.
    fn event_and_booking() -> Json {
        Json::parse(
            r#"{"aggregates":[
              {"name":"Event","attributes":[{"name":"starts_at","type":"StartsAt","list":false}],
               "value_objects":[{"name":"StartsAt","attributes":[{"name":"value","type":"Integer","list":false}]}]},
              {"name":"Booking","attributes":[{"name":"event","type":"Reference<Event>","list":false}],
               "projected_fields":[{"name":"starts_at","reference":"event","remote_field":"starts_at"}]}
            ]}"#,
        )
        .unwrap()
    }

    fn resolved_booking() -> Json {
        with_resolved_projection_types(&event_and_booking()).get("aggregates").map(Json::each).unwrap_or(&[])[1].clone()
    }

    #[test]
    fn a_projection_through_a_single_field_value_object_takes_its_scalar_type() {
        let field = resolved_booking().get("projected_fields").map(Json::each).unwrap_or(&[])[0].clone();

        assert_eq!(field.get("type").and_then(Json::as_str), Some("Integer"));
    }

    #[test]
    fn the_projected_pseudo_attribute_follows_the_remote_type() {
        let attrs = projected_field_pseudo_attributes(&resolved_booking());

        assert_eq!(crate::attr::type_name(&attrs[0]), "Integer");
    }

    #[test]
    fn the_projected_setter_narrows_with_the_remote_types_reader() {
        let setter = emit_set_projected_field(&resolved_booking());

        assert!(setter.contains("\"starts_at\" => self.starts_at = value.and_then(crate::kernel::Value::into_i64),"));
    }

    /// A value object holding a required and an optional value object, and a required and an
    /// optional list of them.
    fn holder_value_object() -> Json {
        Json::parse(
            r#"{
              "name":"Holder",
              "attributes":[
                {"name":"required_note","type":"Note","list":false,"optional":false},
                {"name":"note","type":"Note","list":false,"optional":true},
                {"name":"required_notes","type":"Note","list":true,"optional":false},
                {"name":"notes","type":"Note","list":true,"optional":true}
              ]
            }"#,
        )
        .unwrap()
    }

    #[test]
    fn a_nested_value_object_checks_its_invariants_only_when_it_is_present() {
        let note = Json::parse(r#"{"name":"Note","attributes":[{"name":"text","type":"String","list":false,"optional":false}]}"#).unwrap();
        let by_name: HashMap<String, &Json> = HashMap::from([("Note".to_string(), &note)]);
        let generated = emit_check_invariants(&Exemplar::load(), &holder_value_object(), &by_name, &HashMap::new());

        assert!(generated.contains("self.required_note.check_invariants()?;"));
        assert!(generated.contains("if let Some(value) = &self.note { value.check_invariants()?; }"));
        assert!(generated.contains("for item in &self.required_notes { item.check_invariants()?; }"));
        assert!(generated.contains("if let Some(items) = &self.notes { for item in items { item.check_invariants()?; } }"));
    }
}
