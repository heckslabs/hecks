//! Port of `rust/project/json_codec.rb` — the JSON boundary generator.
//! Mirrors `to_json`/`from_json` for value objects/entities/records and
//! the closed-set codecs, plus `extract_id`/`extract_wants`/
//! `self_identity`. Read the Ruby file's own header comments; this
//! follows its algorithm directly, function for function.

use crate::exemplar::Exemplar;
use crate::json::Json;
use crate::naming;
use std::collections::HashMap;

pub fn json_type_error(struct_name: &str, key: &str, expectation: &str) -> String {
    format!("crate::kernel::Refusal::TypeMismatch({}.to_string())", naming::ruby_inspect_string(&format!("{struct_name}.{key}: expected {expectation}")))
}

pub fn scalar_type_error(struct_name: &str, key: &str, scalar_type: &str, value_var: &str) -> String {
    if scalar_type != "Integer" && scalar_type != "Float" {
        return json_type_error(struct_name, key, scalar_type);
    }
    let template = format!("{struct_name}.{key} expects {scalar_type}, got {{}}");
    format!("crate::kernel::Refusal::TypeMismatch(format!({}, {value_var}.inspect()))", naming::ruby_inspect_string(&template))
}

pub fn scalar_json_accessor(scalar_type: &str) -> &'static str {
    match scalar_type {
        "String" => "as_str",
        "Integer" => "as_i64",
        "Float" => "as_f64",
        other => panic!("no JSON accessor for scalar type {other:?}"),
    }
}

pub fn scalar_from_json_expr(struct_name: &str, key: &str, scalar_type: &str, default: Option<&Json>) -> String {
    let accessor = scalar_json_accessor(scalar_type);
    let wrap = if scalar_type == "String" { ".map(|s| s.to_string())" } else { "" };
    if let Some(default) = default {
        let default_rhs = naming::literal_rhs(default);
        return format!(
            "match v.get({}) {{ Some(x) => x.{accessor}(){wrap}.ok_or_else(|| {})?, None => {default_rhs} }}",
            naming::ruby_inspect_string(key),
            scalar_type_error(struct_name, key, scalar_type, "x")
        );
    }
    format!(
        "{{ let x = v.require({}, {})?; x.{accessor}(){wrap}.ok_or_else(|| {})? }}",
        naming::ruby_inspect_string(key),
        naming::ruby_inspect_string(struct_name),
        scalar_type_error(struct_name, key, scalar_type, "x")
    )
}

pub fn scalar_from_json_value_expr(struct_name: &str, key: &str, scalar_type: &str, value_expr: &str) -> String {
    let accessor = scalar_json_accessor(scalar_type);
    let wrap = if scalar_type == "String" { ".map(|s| s.to_string())" } else { "" };
    format!("{value_expr}.{accessor}(){wrap}.ok_or_else(|| {})?", scalar_type_error(struct_name, key, scalar_type, value_expr))
}

pub fn scalar_to_json_expr(scalar_type: &str, rust_expr: &str) -> String {
    match scalar_type {
        "String" => format!("crate::kernel::Json::Str({rust_expr}.clone())"),
        "Integer" => format!("crate::kernel::Json::int({rust_expr})"),
        "Float" => format!("crate::kernel::Json::Num({rust_expr})"),
        other => panic!("no to_json expr for scalar type {other:?}"),
    }
}

/// `Value.for_attribute` → `fields_for`'s own bare-scalar branch
/// (lib/hecksagain/runtime/value/coercion.rb), at codegen time instead
/// of runtime — port of `json_codec.rb#sole_field_of`. `None` for
/// anything but a genuinely single-field value object, so every other
/// composite branch below is unchanged.
pub fn sole_field_of(type_name: &str, value_objects_by_name: &HashMap<String, &Json>) -> Option<String> {
    let vo = value_objects_by_name.get(type_name)?;
    let attrs = vo.get("attributes").map(Json::each).unwrap_or(&[]);
    if attrs.len() == 1 {
        Some(crate::attr::name(&attrs[0]).to_string())
    } else {
        None
    }
}

/// Port of `json_codec.rb#composite_from_json_expr` — the
/// `NestedType::from_json(expr)?` call, wrapped in
/// `Json::coerce_single_field` (kernel/json.rs) first when `attr`'s own
/// type is single-field. Shared by both composite branches in
/// `emit_from_json_flat`/`emit_from_json_state` below.
pub fn composite_from_json_expr(attr: &Json, value_objects_by_name: &HashMap<String, &Json>, value_expr: &str) -> String {
    let nested_type = naming::rust_ident(crate::attr::type_name(attr));
    match sole_field_of(crate::attr::type_name(attr), value_objects_by_name) {
        Some(sole) => format!("{nested_type}::from_json(&{value_expr}.coerce_single_field({}))?", naming::ruby_inspect_string(&sole)),
        None => format!("{nested_type}::from_json({value_expr})?"),
    }
}

/// `CommandInterpreter::ArgumentGate#refuse_unknown_arguments`'s own
/// allowlist — declared attributes plus every OTHER name a caller is
/// legitimately allowed to address a command by or smuggle a saga's
/// correlation through. Only ever passed for an AGGREGATE-level command's
/// own `from_json` — entity commands run no such check at all.
pub fn command_argument_allowlist(aggregate: &Json, command: &Json, process_managers: &[Json]) -> Vec<String> {
    let references = command.get("references").map(Json::to_s).unwrap_or_default();
    let reference_key = if references.is_empty() { None } else { Some(crate::hecksagain_naming::reference_key(&references)) };

    let identity_heads: Vec<String> = aggregate.get("identified_by").map(Json::each).unwrap_or(&[]).iter().map(|p| p.to_s().split('.').next().unwrap_or("").to_string()).collect();

    let correlation_keys: Vec<String> =
        process_managers.iter().filter_map(|pm| pm.get("correlates_by").map(Json::to_s)).filter_map(|c| c.split('.').next().map(|s| s.to_string())).collect();

    let mut out: Vec<String> = vec!["id".to_string()];
    if let Some(rk) = reference_key {
        out.push(rk);
    }
    out.extend(identity_heads);
    out.extend(correlation_keys);
    let mut seen = Vec::new();
    out.retain(|k| {
        if seen.contains(k) {
            false
        } else {
            seen.push(k.clone());
            true
        }
    });
    out
}

/// Mirrors `json_codec.rb#emit_unknown_argument_check`'s own `<<~RUST`
/// squiggly heredoc EXACTLY, including its own dedent margin — the
/// marker this splices into (`from_json_flat`'s own `let
/// _tmpl_unknown_check_placeholder = ();`) sits at COLUMN 0 in the
/// exemplar template, so this block's own first line lands there too,
/// with every following line indented relative to that. Found live,
/// byte-diffing a real generated aggregate command's `from_json` for the
/// first time — this path was never exercised during the prior stage's
/// prelude-only scope (an aggregate command's own `unknown_argument_
/// allowlist` is never passed there), so an earlier draft's guessed
/// indentation was a real, confirmed mismatch.
fn emit_unknown_argument_check(command_name: &str, known_keys: &[String], declared_names: &[String]) -> String {
    format!(
        "let unknown = v.unknown_keys(&[{}]);\nif !unknown.is_empty() {{\n    return Err(crate::kernel::Refusal::UnknownArgument(format!(\n        \"{command_name} does not declare {{}} — it takes {}\",\n        unknown.join(\", \")\n    )));\n}}\n",
        known_keys.iter().map(|k| naming::ruby_inspect_string(k)).collect::<Vec<_>>().join(", "),
        declared_names.join(", "),
    )
}

pub fn emit_from_json_flat(
    exemplar: &Exemplar,
    struct_name: &str,
    attributes: &[Json],
    value_objects_by_name: &HashMap<String, &Json>,
    unknown_argument_allowlist: Option<&[String]>,
    command_name: Option<&str>,
) -> String {
    let command_name = command_name.unwrap_or(struct_name);
    let field_exprs: Vec<String> = attributes
        .iter()
        .map(|attr| {
            let ident = naming::rust_ident_field(crate::attr::name(attr));
            let key = naming::rust_field(crate::attr::name(attr));
            let scalar = naming::effective_scalar_type(crate::attr::type_name(attr));
            let list = crate::attr::list(attr);
            let optional = crate::attr::optional(attr);

            let rhs = if list && optional {
                let elem_type = naming::rust_ident(crate::attr::type_name(attr));
                let array_error = json_type_error(struct_name, &key, "an array");
                format!(
                    "match v.get({}) {{ Some(x) => Some(x.as_array().ok_or_else(|| {array_error})?.iter().map({elem_type}::from_json).collect::<Result<Vec<_>, crate::kernel::Refusal>>()?), None => None, }}",
                    naming::ruby_inspect_string(&key)
                )
            } else if list {
                let elem_type = naming::rust_ident(crate::attr::type_name(attr));
                format!(
                    "match v.get({}).and_then(crate::kernel::Json::as_array) {{ Some(items) => items.iter().map({elem_type}::from_json).collect::<Result<Vec<_>, crate::kernel::Refusal>>()?, None => Vec::new(), }}",
                    naming::ruby_inspect_string(&key)
                )
            } else if optional && scalar.is_some() {
                format!("match v.get({}) {{ Some(x) => Some({}), None => None, }}", naming::ruby_inspect_string(&key), scalar_from_json_value_expr(struct_name, &key, scalar.unwrap(), "x"))
            } else if optional {
                format!("match v.get({}) {{ Some(x) => Some({}), None => None, }}", naming::ruby_inspect_string(&key), composite_from_json_expr(attr, value_objects_by_name, "x"))
            } else if let Some(scalar) = scalar {
                scalar_from_json_expr(struct_name, &key, scalar, crate::attr::default(attr))
            } else {
                composite_from_json_expr(attr, value_objects_by_name, &format!("v.require({}, {})?", naming::ruby_inspect_string(&key), naming::ruby_inspect_string(struct_name)))
            };
            exemplar.render("field_assignment", &[("tmpl_ident", ident), ("tmpl_rhs_placeholder()", rhs)])
        })
        .collect();

    let unknown_check = match unknown_argument_allowlist {
        Some(allowlist) => {
            let mut known_keys: Vec<String> = attributes.iter().map(|a| naming::rust_field(crate::attr::name(a))).collect();
            for k in allowlist {
                if !known_keys.contains(k) {
                    known_keys.push(k.clone());
                }
            }
            let declared_names: Vec<String> = attributes.iter().map(|a| crate::attr::name(a).to_string()).collect();
            emit_unknown_argument_check(command_name, &known_keys, &declared_names)
        }
        None => String::new(),
    };

    emit_from_json_skeleton(exemplar, struct_name, &field_exprs, &unknown_check)
}

fn emit_from_json_skeleton(exemplar: &Exemplar, struct_name: &str, field_exprs: &[String], unknown_check: &str) -> String {
    let field_block = field_exprs.iter().map(|f| format!("        {f}")).collect::<Vec<_>>().join("\n");
    format!(
        "{}\n",
        exemplar.render(
            "from_json_flat",
            &[
                ("TmplFlatType2", struct_name.to_string()),
                ("let _tmpl_unknown_check_placeholder = ();\n        Ok(Self {", format!("{unknown_check}        Ok(Self {{")),
                ("tmpl_ident: tmpl_rhs_placeholder(),", field_block),
            ],
        )
    )
}

pub fn emit_to_json_flat(exemplar: &Exemplar, struct_name: &str, attributes: &[Json], optional: bool, extra_fields: &[(String, String)], aggregate: Option<&Json>) -> String {
    let mut field_exprs: Vec<String> = attributes
        .iter()
        .map(|attr| {
            let ident = naming::rust_ident_field(crate::attr::name(attr));
            let key = naming::rust_field(crate::attr::name(attr));
            let scalar = naming::effective_scalar_type(crate::attr::type_name(attr));
            let list = crate::attr::list(attr);

            let record_optional_list = list && aggregate.map(|a| crate::shared::list_attr_creation_optional(a, crate::attr::name(attr))).unwrap_or(false);
            let field_optional = optional || crate::attr::optional(attr);
            let list_is_optional = if aggregate.is_some() { record_optional_list } else { crate::attr::optional(attr) };

            let value_expr = if list && list_is_optional {
                format!("self.{ident}.as_ref().map(|v| crate::kernel::Json::Array(v.iter().map(|x| x.to_json()).collect())).unwrap_or(crate::kernel::Json::Null)")
            } else if list {
                format!("crate::kernel::Json::Array(self.{ident}.iter().map(|x| x.to_json()).collect())")
            } else if field_optional && scalar.is_some() {
                format!("self.{ident}.as_ref().map(|v| {}).unwrap_or(crate::kernel::Json::Null)", scalar_to_json_expr(scalar.unwrap(), "v"))
            } else if field_optional {
                format!("self.{ident}.as_ref().map(|v| v.to_json()).unwrap_or(crate::kernel::Json::Null)")
            } else if let Some(scalar) = scalar {
                scalar_to_json_expr(scalar, &format!("self.{ident}"))
            } else {
                format!("self.{ident}.to_json()")
            };
            exemplar.render("to_json_field", &[("\"tmpl_field_name\"", naming::ruby_inspect_string(&key)), ("tmpl_json_value_placeholder()", value_expr)])
        })
        .collect();

    field_exprs.extend(extra_fields.iter().map(|(key, expr)| exemplar.render("to_json_field", &[("\"tmpl_field_name\"", naming::ruby_inspect_string(key)), ("tmpl_json_value_placeholder()", expr.clone())])));
    let field_block = field_exprs.iter().map(|f| format!("        {f}")).collect::<Vec<_>>().join("\n");

    format!("{}\n", exemplar.render("to_json_flat", &[("TmplFlatType2", struct_name.to_string()), ("tmpl_to_json_field_block()", field_block)]))
}

pub fn emit_from_json_state(
    exemplar: &Exemplar,
    struct_name: &str,
    attributes: &[Json],
    value_objects_by_name: &HashMap<String, &Json>,
    optional: bool,
    extra_fields: &[(String, String)],
    aggregate: Option<&Json>,
) -> String {
    let mut field_exprs: Vec<String> = attributes
        .iter()
        .map(|attr| {
            let ident = naming::rust_ident_field(crate::attr::name(attr));
            let key = naming::rust_field(crate::attr::name(attr));
            let scalar = naming::effective_scalar_type(crate::attr::type_name(attr));
            let list = crate::attr::list(attr);

            let record_optional_list = list && aggregate.map(|a| crate::shared::list_attr_creation_optional(a, crate::attr::name(attr))).unwrap_or(false);
            let list_is_optional = if aggregate.is_some() { record_optional_list } else { crate::attr::optional(attr) };
            let field_optional = optional || crate::attr::optional(attr);

            let rhs = if list && list_is_optional {
                let elem_type = naming::rust_ident(crate::attr::type_name(attr));
                let array_error = json_type_error(struct_name, &key, "an array");
                format!(
                    "match v.get({}) {{ Some(&crate::kernel::Json::Null) | None => None, Some(x) => Some(x.as_array().ok_or_else(|| {array_error})?.iter().map({elem_type}::from_json).collect::<Result<Vec<_>, crate::kernel::Refusal>>()?), }}",
                    naming::ruby_inspect_string(&key)
                )
            } else if list {
                let elem_type = naming::rust_ident(crate::attr::type_name(attr));
                format!(
                    "match v.get({}).and_then(crate::kernel::Json::as_array) {{ Some(items) => items.iter().map({elem_type}::from_json).collect::<Result<Vec<_>, crate::kernel::Refusal>>()?, None => Vec::new(), }}",
                    naming::ruby_inspect_string(&key)
                )
            } else if field_optional && scalar.is_some() {
                format!(
                    "match v.get({}) {{ Some(&crate::kernel::Json::Null) | None => None, Some(x) => Some({}), }}",
                    naming::ruby_inspect_string(&key),
                    scalar_from_json_value_expr(struct_name, &key, scalar.unwrap(), "x")
                )
            } else if field_optional {
                format!(
                    "match v.get({}) {{ Some(&crate::kernel::Json::Null) | None => None, Some(x) => Some({}), }}",
                    naming::ruby_inspect_string(&key),
                    composite_from_json_expr(attr, value_objects_by_name, "x")
                )
            } else if let Some(scalar) = scalar {
                scalar_from_json_expr(struct_name, &key, scalar, crate::attr::default(attr))
            } else {
                composite_from_json_expr(attr, value_objects_by_name, &format!("v.require({}, {})?", naming::ruby_inspect_string(&key), naming::ruby_inspect_string(struct_name)))
            };
            exemplar.render("field_assignment", &[("tmpl_ident", ident), ("tmpl_rhs_placeholder()", rhs)])
        })
        .collect();

    for (key, _serialize_expr) in extra_fields {
        let ident = naming::rust_ident_field(key);
        let rhs = format!("v.require({}, {})?.as_str().ok_or_else(|| {})?.to_string()", naming::ruby_inspect_string(key), naming::ruby_inspect_string(struct_name), json_type_error(struct_name, key, "a string"));
        field_exprs.push(exemplar.render("field_assignment", &[("tmpl_ident", ident), ("tmpl_rhs_placeholder()", rhs)]));
    }

    emit_from_json_skeleton(exemplar, struct_name, &field_exprs, "")
}

pub fn emit_closed_set_codec(exemplar: &Exemplar, vo: &Json) -> String {
    let name = naming::rust_ident(vo.get("name").and_then(Json::as_str).unwrap_or(""));
    let attributes = vo.get("attributes").map(Json::each).unwrap_or(&[]);
    let field_name = naming::rust_field(crate::attr::name(&attributes[0]));
    let members = vo.get("members").map(Json::each).unwrap_or(&[]);

    let rows: Vec<(String, String)> = members
        .iter()
        .map(|row| {
            let pairs = row.as_array().unwrap_or(&[]);
            let first = pairs.first().and_then(Json::as_array).unwrap_or(&[]);
            let raw = first.get(1).map(Json::to_s).unwrap_or_default();
            (naming::closed_set_variant(&raw), raw)
        })
        .collect();

    let row_subs: Vec<Vec<(&str, String)>> = rows
        .iter()
        .map(|(variant, raw)| vec![("TmplKind", name.clone()), ("TmplMemberA", variant.clone()), ("\"tmpl_member_a\"", naming::ruby_inspect_string(raw))])
        .collect();

    let type_name = vo.get("name").and_then(Json::as_str).unwrap_or("").to_string();
    let admitted = rows.iter().map(|(_v, raw)| naming::ruby_inspect_string(raw)).collect::<Vec<_>>().join(", ");

    exemplar.assemble(
        "closed_set_codec",
        &[
            ("TmplKind", name),
            ("\"tmpl_field_name\"", naming::ruby_inspect_string(&field_name)),
            ("tmpl_field_name", field_name),
            ("\"tmpl_closed_set_type\"", naming::ruby_inspect_string(&type_name)),
            ("\"tmpl_closed_set_admitted\"", naming::ruby_inspect_string(&admitted)),
        ],
        &[
            ("closed_set_codec:TO_JSON_ARM", exemplar.render_each("closed_set_codec:TO_JSON_ARM", &row_subs, "\n")),
            ("closed_set_codec:FROM_JSON_ARM", exemplar.render_each("closed_set_codec:FROM_JSON_ARM", &row_subs, "\n")),
        ],
    )
}

pub fn emit_closed_set_table_codec(exemplar: &Exemplar, vo: &Json) -> String {
    let name = naming::rust_ident(vo.get("name").and_then(Json::as_str).unwrap_or(""));
    let const_name = naming::screaming_snake(vo.get("name").and_then(Json::as_str).unwrap_or(""));
    let attributes = vo.get("attributes").map(Json::each).unwrap_or(&[]);

    let to_json_fields: Vec<String> = attributes
        .iter()
        .map(|attr| {
            let key = naming::rust_field(crate::attr::name(attr));
            let ident = naming::rust_ident_field(crate::attr::name(attr));
            let scalar = naming::effective_scalar_type(crate::attr::type_name(attr));
            let value_expr = match scalar {
                Some("String") => format!("crate::kernel::Json::Str(self.{ident}.to_string())"),
                Some("Integer") => format!("crate::kernel::Json::int(self.{ident})"),
                Some("Float") => format!("crate::kernel::Json::Num(self.{ident})"),
                _ => String::new(),
            };
            exemplar.render("to_json_field", &[("\"tmpl_field_name\"", naming::ruby_inspect_string(&key)), ("tmpl_json_value_placeholder()", value_expr)])
        })
        .collect();
    let to_json_fields_block = to_json_fields.iter().map(|f| format!("        {f}")).collect::<Vec<_>>().join("\n");

    let match_conditions: Vec<String> = attributes
        .iter()
        .map(|attr| {
            let key = naming::rust_field(crate::attr::name(attr));
            let ident = naming::rust_ident_field(crate::attr::name(attr));
            let accessor = scalar_json_accessor(naming::effective_scalar_type(crate::attr::type_name(attr)).unwrap());
            exemplar.render(
                "closed_set_table_from_json_condition",
                &[("\"tmpl_field_name\"", naming::ruby_inspect_string(&key)), ("tmpl_accessor_fn", format!("crate::kernel::Json::{accessor}")), ("tmpl_field", ident)],
            )
        })
        .collect();

    exemplar.render(
        "closed_set_table_codec",
        &[
            ("TmplTableRow", name),
            ("tmpl_to_json_fields_block()", to_json_fields_block),
            ("TMPL_TABLE", const_name),
            ("tmpl_from_json_conditions()", match_conditions.join(" && ")),
        ],
    )
}

pub fn extract_id_supported(aggregate: &Json) -> bool {
    let identified_by = aggregate.get("identified_by").map(Json::each).unwrap_or(&[]);
    identified_by.iter().all(|path| {
        let path = path.as_str().unwrap_or("");
        let mut parts = path.split('.');
        let head = parts.next().unwrap_or("");
        let rest_any = parts.next().is_some();
        rest_any || !head.is_empty()
    })
}

pub fn emit_extract_id(exemplar: &Exemplar, aggregate: &Json) -> String {
    let name = naming::rust_ident(aggregate.get("name").and_then(Json::as_str).unwrap_or(""));
    let identified_by: Vec<String> = aggregate.get("identified_by").map(Json::each).unwrap_or(&[]).iter().map(Json::to_s).collect();
    let reference_key = crate::hecksagain_naming::snake(aggregate.get("name").and_then(Json::as_str).unwrap_or(""));

    let tier1_subs: Vec<Vec<(&str, String)>> =
        identified_by.iter().enumerate().map(|(i, path)| vec![("\"tmpl_path\"", naming::ruby_inspect_string(path)), ("c0", format!("c{i}"))]).collect();

    let tier1_join = if identified_by.len() == 1 {
        "c0".to_string()
    } else {
        format!("vec![{}].join(\":\")", (0..identified_by.len()).map(|i| format!("c{i}")).collect::<Vec<_>>().join(", "))
    };

    let mut tried = identified_by.clone();
    tried.push("id".to_string());
    tried.push(reference_key.clone());
    let tried = tried.join(", ");

    exemplar.compose(
        "extract_id",
        &[
            ("TmplExtractIdType", name.clone()),
            ("\"tmpl_reference_key\"", naming::ruby_inspect_string(&reference_key)),
            ("tmpl_tier1_join_placeholder()", tier1_join),
            ("\"tmpl_error_text\"", naming::ruby_inspect_string(&format!("{name}: no identity found (tried {tried})"))),
        ],
        "extract_id:TIER1_LINE",
        &tier1_subs,
        "\n",
    )
}

pub fn emit_extract_wants(exemplar: &Exemplar, entity: &Json) -> String {
    let name = naming::rust_ident(entity.get("name").and_then(Json::as_str).unwrap_or(""));
    let identified_by: Vec<String> = entity.get("identified_by").map(Json::each).unwrap_or(&[]).iter().map(Json::to_s).collect();

    let tier1_subs: Vec<Vec<(&str, String)>> =
        identified_by.iter().enumerate().map(|(i, path)| vec![("\"tmpl_path\"", naming::ruby_inspect_string(path)), ("c0", format!("c{i}"))]).collect();

    let wants_join = if identified_by.len() == 1 {
        "c0".to_string()
    } else {
        format!("vec![{}].join(\", \")", (0..identified_by.len()).map(|i| format!("c{i}")).collect::<Vec<_>>().join(", "))
    };

    exemplar.compose("extract_wants", &[("TmplExtractWantsType", name), ("tmpl_wants_join_placeholder()", wants_join)], "extract_wants:TIER1_LINE", &tier1_subs, "\n")
}

pub fn emit_self_identity(exemplar: &Exemplar, entity: &Json) -> String {
    let name = naming::rust_ident(entity.get("name").and_then(Json::as_str).unwrap_or(""));
    let identified_by = entity.get("identified_by").map(Json::each).unwrap_or(&[]);

    let components: Vec<String> = identified_by
        .iter()
        .map(|path| {
            let path = path.as_str().unwrap_or("");
            let mut parts = path.split('.');
            let head = parts.next().unwrap_or("");
            let mut out = format!("self.{}", naming::rust_ident_field(head));
            for seg in parts {
                out.push('.');
                out.push_str(&naming::rust_ident_field(seg));
            }
            format!("{out}.to_string()")
        })
        .collect();
    let body = if components.len() == 1 { components[0].clone() } else { format!("vec![{}].join(\":\")", components.join(", ")) };

    exemplar.render("self_identity", &[("TmplSelfIdentityType", name), ("tmpl_identity_body_placeholder()", body)])
}
