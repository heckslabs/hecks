//! Port of `rust/project/types.rb` — `emit_check_invariants`,
//! `emit_closed_set_table`, `emit_value_object`, `emit_entity`,
//! `emit_record`, `unsupported_attribute_types`. Mirrors the Ruby source
//! directly; read that file's own header comments for the "why" behind
//! each shape.

use crate::exemplar::Exemplar;
use crate::fielded;
use crate::json::Json;
use crate::naming;
use std::collections::HashMap;

pub fn emit_check_invariants(exemplar: &Exemplar, vo: &Json, value_objects_by_name: &HashMap<String, &Json>, aggregates_by_name: &HashMap<String, &Json>) -> String {
    let name = naming::rust_ident(vo.get("name").and_then(Json::as_str).unwrap_or(""));
    let type_name = vo.get("name").and_then(Json::as_str).unwrap_or("").to_string();
    let invariants = vo.get("invariants").map(Json::each).unwrap_or(&[]);

    // Mirrors `types.rb`'s own `<<~RUST.rstrip` heredoc EXACTLY, including
    // its dedent margin — the raw Ruby source's own `{`/closing `}` sit at
    // the heredoc's OWN minimum indentation, so the squiggly-heredoc
    // dedent leaves this block FLUSH LEFT (the `{`/`}` at column 0, not
    // re-indented to match its embedding context) — found live, byte-
    // diffing against Ruby's real output: a "nicely re-indented" version
    // (this function's own first draft) was a real, confirmed mismatch.
    let mut body: Vec<String> = invariants
        .iter()
        .map(|inv| {
            let canonical = inv.get("canonical").and_then(Json::as_str).unwrap_or("");
            let description = inv.get("description").and_then(Json::as_str).unwrap_or("");
            let expr = crate::expr_emitter::emit_predicate(canonical);
            format!(
                "{{\n    let ctx = crate::kernel::EvalContext {{ args: &crate::kernel::NoFields, instance: self }};\n    if !crate::kernel::interpret(&{expr}, &ctx)?.truthy() {{\n        let mut offered = self.to_json();\n        if let crate::kernel::Json::Object(fields) = &mut offered {{\n            fields.sort_by(|a, b| a.0.cmp(&b.0));\n        }}\n        let offered = offered.to_json_string();\n        return Err(crate::kernel::Refusal::InvariantViolation(crate::kernel::RefusalSite::InvariantViolationValueObjectInvariant.render(&[\n            (\"name\", {}),\n            (\"description\", {}),\n            (\"offered\", offered.as_str()),\n        ])));\n    }}\n}}",
                naming::ruby_inspect_string(&type_name),
                naming::ruby_inspect_string(description),
            )
        })
        .collect();

    let attributes = vo.get("attributes").map(Json::each).unwrap_or(&[]);

    for attr in attributes {
        if crate::attr::list(attr) {
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

    for attr in attributes {
        if naming::effective_scalar_type(crate::attr::type_name(attr)).is_some() {
            continue;
        }
        let is_plain_nested = matches!(value_objects_by_name.get(crate::attr::type_name(attr)), Some(v) if !v.get("closed_set").map(Json::as_bool).unwrap_or(false));
        if !is_plain_nested {
            continue;
        }
        let field = naming::rust_ident_field(crate::attr::name(attr));
        if crate::attr::list(attr) {
            body.push(format!("        for item in &self.{field} {{ item.check_invariants()?; }}"));
        } else {
            body.push(format!("        self.{field}.check_invariants()?;"));
        }
    }

    format!("impl {name} {{\n    pub fn check_invariants(&self) -> Result<(), crate::kernel::Refusal> {{\n{}\n        Ok(())\n    }}\n}}\n", body.join("\n"))
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

/// Ruby's `"".to_i`/`"abc".to_i` — leading-numeric-prefix parse,
/// defaulting to 0 for anything that doesn't start with a valid integer.
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

/// Ruby's `"".to_f`/`"abc".to_f` — same leading-prefix idea, for a float.
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

/// `unsupported_attribute_types(aggregate, value_objects_by_name)`.
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
