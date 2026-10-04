//! Port of `rust/project/json_codec.rb`, the JSON boundary generator: `to_json`/`from_json`
//! codecs, closed-set codecs, and `extract_id`/`extract_wants`/`self_identity`.

use crate::exemplar::Exemplar;
use crate::json::Json;
use crate::naming;
use std::collections::HashMap;

pub fn json_type_error(struct_name: &str, key: &str, expectation: &str) -> String {
    format!("crate::kernel::Refusal::TypeMismatch({}.to_string())", naming::ruby_inspect_string(&format!("{struct_name}.{key}: expected {expectation}")))
}

// The refusal for a scalar offered where a list argument goes; worded as Ruby's
// `Value.refuse_scalar_list`, with the offered value known only at runtime.
pub fn list_shape_error(struct_name: &str, key: &str, element_type: &str, value_var: &str) -> String {
    let template = format!("{struct_name}.{key} expects list_of({element_type}), got {{}}");
    format!("crate::kernel::Refusal::TypeMismatch(format!({}, {value_var}.inspect()))", naming::ruby_inspect_string(&template))
}

// A String field refuses only composite-shaped (or null) values, as Ruby's
// `Value::Coercion#check_scalar_shapes` does; the offered shape is only known at runtime.
pub fn scalar_type_error(struct_name: &str, key: &str, scalar_type: &str, value_var: &str) -> String {
    if scalar_type != "Integer" && scalar_type != "Float" && scalar_type != "String" {
        return json_type_error(struct_name, key, scalar_type);
    }
    let template = format!("{struct_name}.{key} expects {scalar_type}, got {{}}");
    let proper = format!("crate::kernel::Refusal::TypeMismatch(format!({}, {value_var}.inspect()))", naming::ruby_inspect_string(&template));
    if scalar_type != "String" {
        return proper;
    }
    let generic = json_type_error(struct_name, key, scalar_type);
    // `Json::Null` words like a composite: Ruby's `check_required_fields` says "got nil".
    format!("if matches!({value_var}, crate::kernel::Json::Array(_) | crate::kernel::Json::Object(_) | crate::kernel::Json::Null) {{ {proper} }} else {{ {generic} }}")
}

/// A missing non-optional field refuses as "{type}.{field} expects {expected}, got nil".
pub fn required_field_expr(struct_name: &str, key: &str, expected: &str) -> String {
    let message = format!("{struct_name}.{key} expects {expected}, got nil");
    format!("v.get({}).ok_or_else(|| crate::kernel::Refusal::TypeMismatch({}.to_string()))?", naming::ruby_inspect_string(key), naming::ruby_inspect_string(&message))
}

pub fn scalar_json_accessor(scalar_type: &str) -> &'static str {
    match scalar_type {
        "String" => "as_str",
        "Integer" => "as_i64",
        "Float" => "as_f64",
        "TrueClass" | "FalseClass" => "as_bool",
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
        "{{ let x = {}; x.{accessor}(){wrap}.ok_or_else(|| {})? }}",
        required_field_expr(struct_name, key, scalar_type),
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
        "Float" => format!("crate::kernel::Json::Float({rust_expr})"),
        "TrueClass" | "FalseClass" => format!("crate::kernel::Json::Bool({rust_expr})"),
        other => panic!("no to_json expr for scalar type {other:?}"),
    }
}

/// The attribute name of a single-field value object (Ruby's bare-scalar shorthand), else `None`.
pub fn sole_field_of(type_name: &str, value_objects_by_name: &HashMap<String, &Json>) -> Option<String> {
    let vo = value_objects_by_name.get(type_name)?;
    let attrs = vo.get("attributes").map(Json::each).unwrap_or(&[]);
    if attrs.len() == 1 {
        Some(crate::attr::name(&attrs[0]).to_string())
    } else {
        None
    }
}

/// `NestedType::from_json(expr)?`, via `coerce_single_field` for a single-field type.
/// A multi-field type is shape-checked first: only this site knows the attribute name Ruby quotes.
pub fn composite_from_json_expr(attr: &Json, value_objects_by_name: &HashMap<String, &Json>, value_expr: &str) -> String {
    let nested_type = naming::rust_ident(crate::attr::type_name(attr));
    match sole_field_of(crate::attr::type_name(attr), value_objects_by_name) {
        Some(sole) => format!("{nested_type}::from_json(&{value_expr}.coerce_single_field({}))?", naming::ruby_inspect_string(&sole)),
        None => format!(
            "{nested_type}::from_json({value_expr}.expect_value_object_shape({}, {})?)?",
            naming::ruby_inspect_string(crate::attr::name(attr)),
            naming::ruby_inspect_string(crate::attr::type_name(attr))
        ),
    }
}

/// Scalar elements (`list_of(String)`, `has_many` references) have no generated `from_json`;
/// they read as scalars minus the trailing `?`. Single-field value objects coerce bare scalars.
pub fn list_element_from_json_mapper(struct_name: &str, key: &str, attr: &Json, value_objects_by_name: &HashMap<String, &Json>) -> String {
    match naming::effective_scalar_type(crate::attr::type_name(attr)) {
        Some(scalar) => {
            let body = scalar_from_json_value_expr(struct_name, key, scalar, "item");
            let body = body.strip_suffix('?').unwrap_or(&body);
            format!("|item| {body}")
        }
        None => {
            let nested_type = naming::rust_ident(crate::attr::type_name(attr));
            match sole_field_of(crate::attr::type_name(attr), value_objects_by_name) {
                Some(sole) => format!("|item| {nested_type}::from_json(&item.coerce_single_field({}))", naming::ruby_inspect_string(&sole)),
                None => format!("{nested_type}::from_json"),
            }
        }
    }
}

/// Inverse of `list_element_from_json_mapper`: scalar elements have no `.to_json()` method.
pub fn list_element_to_json_expr(attr: &Json) -> String {
    match naming::effective_scalar_type(crate::attr::type_name(attr)) {
        Some(scalar) => scalar_to_json_expr(scalar, "x"),
        None => "x.to_json()".to_string(),
    }
}

/// A required composite argument offered as `null` reads as an empty object, like an omitted key.
///
/// Builds one owned value up front: mixing arm-local temporaries does not borrow-check (E0716).
pub fn required_composite_argument_expr(struct_name: &str, key: &str, attr: &Json, value_objects_by_name: &HashMap<String, &Json>) -> String {
    let fetch = required_field_expr(struct_name, key, crate::attr::type_name(attr));
    let nested_type = naming::rust_ident(crate::attr::type_name(attr));
    let guarded = format!("match {fetch} {{ crate::kernel::Json::Null => crate::kernel::Json::Object(Vec::new()), other => other.clone() }}");
    match sole_field_of(crate::attr::type_name(attr), value_objects_by_name) {
        Some(sole) => format!("{nested_type}::from_json(&({guarded}).coerce_single_field({}))?", naming::ruby_inspect_string(&sole)),
        None => format!(
            "{nested_type}::from_json(({guarded}).expect_value_object_shape({}, {})?)?",
            naming::ruby_inspect_string(crate::attr::name(attr)),
            naming::ruby_inspect_string(crate::attr::type_name(attr))
        ),
    }
}

/// The names `ArgumentGate#refuse_unknown_arguments` accepts: declared attributes plus the
/// reference key, identity heads and saga correlation keys.
///
/// `extra_identity_heads` is the entity's own identity head for entity commands, else `&[]`.
pub fn command_argument_allowlist(aggregate: &Json, command: &Json, process_managers: &[Json], extra_identity_heads: &[String]) -> Vec<String> {
    let references = command.get("references").map(Json::to_s).unwrap_or_default();
    let reference_key = if references.is_empty() { None } else { Some(crate::hecks_naming::reference_key(&references)) };

    let identity_heads: Vec<String> = aggregate.get("identified_by").map(Json::each).unwrap_or(&[]).iter().map(|p| p.to_s().split('.').next().unwrap_or("").to_string()).collect();

    let correlation_keys: Vec<String> =
        process_managers.iter().filter_map(|pm| pm.get("correlates_by").map(Json::to_s)).filter_map(|c| c.split('.').next().map(|s| s.to_string())).collect();

    let mut out: Vec<String> = vec!["id".to_string()];
    if let Some(rk) = reference_key {
        out.push(rk);
    }
    out.extend(identity_heads);
    out.extend(extra_identity_heads.iter().cloned());
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

/// `ArgumentGate#refuse_absent_arguments`, generated: every declared non-optional name the JSON
/// omits, sorted, refuses as `AbsentArgument` before any field is built.
///
/// Goes through the site's `<Variant>Args` struct, so leaving an argument out does not compile.
fn emit_absent_argument_check(command_name: &str, attributes: &[Json]) -> String {
    let mut required: Vec<String> = attributes.iter().filter(|a| !crate::attr::optional(a)).map(|a| naming::rust_field(crate::attr::name(a))).collect();
    required.sort();
    if required.is_empty() {
        return String::new();
    }
    let declared: Vec<String> = attributes.iter().map(|a| crate::attr::name(a).to_string()).collect();
    format!(
        "let absent: Vec<&str> = [{}].into_iter().filter(|key| v.get(key).is_none()).collect();\nif !absent.is_empty() {{\n    return Err(crate::kernel::Refusal::AbsentArgument(crate::kernel::refusal_wording::AbsentArgumentAbsentArgsArgs {{\n        command: {},\n        absent: &absent,\n        declared: &[{}],\n    }}.render_args()));\n}}\n",
        required.iter().map(|k| naming::ruby_inspect_string(k)).collect::<Vec<_>>().join(", "),
        naming::ruby_inspect_string(command_name),
        declared.iter().map(|k| naming::ruby_inspect_string(k)).collect::<Vec<_>>().join(", "),
    )
}

/// Both name lists go over raw to `UnknownArgumentUnknownArgsArgs::render_args`, which reads
/// the same vocabulary rows as Ruby's `RefusalWording.render_site`; no join or "none" here.
fn emit_unknown_argument_check(command_name: &str, known_keys: &[String], declared_names: &[String]) -> String {
    format!(
        "let unknown = v.unknown_keys(&[{}]);\nif !unknown.is_empty() {{\n    let unknown: Vec<&str> = unknown.iter().map(|key| key.as_str()).collect();\n    return Err(crate::kernel::Refusal::UnknownArgument(crate::kernel::refusal_wording::UnknownArgumentUnknownArgsArgs {{\n        command: {},\n        unknown: &unknown,\n        declared: &[{}],\n    }}.render_args()));\n}}\n",
        known_keys.iter().map(|k| naming::ruby_inspect_string(k)).collect::<Vec<_>>().join(", "),
        naming::ruby_inspect_string(command_name),
        declared_names.iter().map(|k| naming::ruby_inspect_string(k)).collect::<Vec<_>>().join(", "),
    )
}

/// The unknown-argument check then the absent-argument check, in Ruby's DISPATCH_ORDER.
pub fn unknown_and_absent_argument_checks(command_name: &str, attributes: &[Json], unknown_argument_allowlist: Option<&[String]>, absent_argument_check: bool) -> String {
    let mut check = match unknown_argument_allowlist {
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
    if absent_argument_check {
        check.push_str(&emit_absent_argument_check(command_name, attributes));
    }
    check
}

/// One generated function per argument-gate step, beside a command's `from_json`, for
/// `kernel::decode_aggregate_arguments`/`decode_entity_arguments` to call in step order.
pub fn emit_argument_gates(struct_name: &str, command_name: &str, attributes: &[Json], unknown_argument_allowlist: Option<&[String]>) -> String {
    let unknown = match unknown_argument_allowlist {
        Some(_) => unknown_and_absent_argument_checks(command_name, attributes, unknown_argument_allowlist, false),
        None => String::new(),
    };
    let absent = emit_absent_argument_check(command_name, attributes);

    format!(
        "impl {struct_name} {{\n{}\n\n{}\n\n{}\n}}\n",
        argument_gate_fn("decode_arguments", &emit_object_shape_check(struct_name)),
        argument_gate_fn("refuse_unknown_arguments", &unknown),
        argument_gate_fn("refuse_absent_arguments", &absent),
    )
}

/// An empty body still gets its function (the kernel calls every step); `_v` avoids a warning.
fn argument_gate_fn(name: &str, body: &str) -> String {
    let parameter = if body.is_empty() { "_v" } else { "v" };
    format!("    pub fn {name}({parameter}: &crate::kernel::Json) -> Result<(), crate::kernel::Refusal> {{\n{body}        Ok(())\n    }}")
}

/// With `interleave_checks`, each field's `let` is followed by its admits and invariant checks
/// before the next field is built, as in Ruby's `coerce_declared_arguments`; this needs
/// `aggregates_by_name`. Otherwise the value object is one struct literal.
#[allow(clippy::too_many_arguments)]
pub fn emit_from_json_flat(
    exemplar: &Exemplar,
    struct_name: &str,
    attributes: &[Json],
    value_objects_by_name: &HashMap<String, &Json>,
    unknown_argument_allowlist: Option<&[String]>,
    command_name: Option<&str>,
    absent_argument_check: bool,
    interleave_checks: bool,
    aggregates_by_name: Option<&HashMap<String, &Json>>,
) -> String {
    let command_name = command_name.unwrap_or(struct_name);
    let idents: Vec<String> = attributes.iter().map(|attr| naming::rust_ident_field(crate::attr::name(attr))).collect();
    let field_exprs: Vec<String> = attributes
        .iter()
        .zip(idents.iter())
        .map(|(attr, ident)| {
            let key = naming::rust_field(crate::attr::name(attr));
            let scalar = naming::effective_scalar_type(crate::attr::type_name(attr));
            let list = crate::attr::list(attr);
            let optional = crate::attr::optional(attr);

            let rhs = if list && optional {
                let mapper = list_element_from_json_mapper(struct_name, &key, attr, value_objects_by_name);
                let array_error = json_type_error(struct_name, &key, "an array");
                format!(
                    "match v.get({}) {{ Some(crate::kernel::Json::Null) | None => None, Some(x) => Some(x.as_array().ok_or_else(|| {array_error})?.iter().map({mapper}).collect::<Result<Vec<_>, crate::kernel::Refusal>>()?) }}",
                    naming::ruby_inspect_string(&key)
                )
            } else if list {
                let mapper = list_element_from_json_mapper(struct_name, &key, attr, value_objects_by_name);
                // A list argument is an array: a lone scalar is refused, as Ruby's
                // `Value.refuse_scalar_list` does; null and an absent key are the empty list.
                let shape_error = list_shape_error(struct_name, &key, crate::attr::type_name(attr), "x");
                format!(
                    "match v.get({}) {{ Some(crate::kernel::Json::Null) | None => Vec::new(), Some(x) => x.as_array().ok_or_else(|| {shape_error})?.iter().map({mapper}).collect::<Result<Vec<_>, crate::kernel::Refusal>>()?, }}",
                    naming::ruby_inspect_string(&key)
                )
            } else if optional && scalar.is_some() {
                // An optional argument offered as null is the same absence as an omitted key.
                format!("match v.get({}) {{ Some(crate::kernel::Json::Null) | None => None, Some(x) => Some({}) }}", naming::ruby_inspect_string(&key), scalar_from_json_value_expr(struct_name, &key, scalar.unwrap(), "x"))
            } else if optional {
                format!("match v.get({}) {{ Some(crate::kernel::Json::Null) | None => None, Some(x) => Some({}) }}", naming::ruby_inspect_string(&key), composite_from_json_expr(attr, value_objects_by_name, "x"))
            } else if let Some(scalar) = scalar {
                scalar_from_json_expr(struct_name, &key, scalar, crate::attr::default(attr))
            } else if absent_argument_check {
                // The argument door only; see `required_composite_argument_expr`.
                required_composite_argument_expr(struct_name, &key, attr, value_objects_by_name)
            } else {
                composite_from_json_expr(attr, value_objects_by_name, &required_field_expr(struct_name, &key, crate::attr::type_name(attr)))
            };

            if interleave_checks {
                let checks = crate::commands::argument_check_lines(
                    exemplar,
                    attr,
                    ident,
                    aggregates_by_name.expect("aggregates_by_name required when interleave_checks is true"),
                    value_objects_by_name,
                );
                let mut block = format!("        let {ident} = {rhs};");
                for check in checks {
                    block.push('\n');
                    block.push_str(&check);
                }
                block
            } else {
                exemplar.render("field_assignment", &[("tmpl_ident", ident.clone()), ("tmpl_rhs_placeholder()", rhs)])
            }
        })
        .collect();

    let unknown_check = unknown_and_absent_argument_checks(command_name, attributes, unknown_argument_allowlist, absent_argument_check);

    let shorthand_fields = if interleave_checks { Some(idents.as_slice()) } else { None };
    emit_from_json_skeleton(exemplar, struct_name, &field_exprs, &unknown_check, shorthand_fields)
}

fn emit_object_shape_check(struct_name: &str) -> String {
    format!(
        "if !matches!(v, crate::kernel::Json::Object(_)) {{\n    return Err(crate::kernel::Refusal::TypeMismatch(format!(\"{struct_name} expects an object, got {{}}\", v.inspect())));\n}}\n"
    )
}

/// `shorthand_fields: None` folds `ident: rhs,` lines into the struct literal; `Some(idents)`
/// puts the `let`+check blocks in the preamble and closes the literal with shorthand init.
fn emit_from_json_skeleton(exemplar: &Exemplar, struct_name: &str, field_exprs: &[String], unknown_check: &str, shorthand_fields: Option<&[String]>) -> String {
    let mut preamble = format!("{}{unknown_check}", emit_object_shape_check(struct_name));
    let field_block = match shorthand_fields {
        Some(idents) => {
            for f in field_exprs {
                preamble.push_str(f);
                preamble.push('\n');
            }
            idents.iter().map(|f| format!("        {f},")).collect::<Vec<_>>().join("\n")
        }
        None => field_exprs.iter().map(|f| format!("        {f}")).collect::<Vec<_>>().join("\n"),
    };
    format!(
        "{}\n",
        exemplar.render(
            "from_json_flat",
            &[
                ("TmplFlatType2", struct_name.to_string()),
                ("let _tmpl_unknown_check_placeholder = ();\n        Ok(Self {", format!("{preamble}        Ok(Self {{")),
                ("tmpl_ident: tmpl_rhs_placeholder(),", field_block),
            ],
        )
    )
}

pub fn emit_to_json_flat(exemplar: &Exemplar, struct_name: &str, attributes: &[Json], value_objects_by_name: &HashMap<String, &Json>, optional: bool, extra_fields: &[(String, String)], aggregate: Option<&Json>) -> String {
    let mut field_exprs: Vec<String> = attributes
        .iter()
        .map(|attr| {
            let ident = naming::rust_ident_field(crate::attr::name(attr));
            let key = naming::rust_field(crate::attr::name(attr));
            let scalar = naming::effective_scalar_type(crate::attr::type_name(attr));
            let list = crate::attr::list(attr);

            let record_optional_list = list && aggregate.map(|a| crate::shared::list_attr_creation_optional(a, crate::attr::name(attr), value_objects_by_name)).unwrap_or(false);
            let field_optional = optional || crate::attr::optional(attr);
            let list_is_optional = if aggregate.is_some() { record_optional_list } else { crate::attr::optional(attr) };

            let elem_to_json = if list { Some(list_element_to_json_expr(attr)) } else { None };
            let value_expr = if list && list_is_optional {
                format!("self.{ident}.as_ref().map(|v| crate::kernel::Json::Array(v.iter().map(|x| {}).collect())).unwrap_or(crate::kernel::Json::Null)", elem_to_json.as_deref().unwrap())
            } else if list {
                format!("crate::kernel::Json::Array(self.{ident}.iter().map(|x| {}).collect())", elem_to_json.as_deref().unwrap())
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
    // `corrects` flag fields are read off `aggregate`, not `extra_fields` (String-only).
    if let Some(aggregate) = aggregate {
        field_exprs.extend(crate::bridging::correctable_event_names(aggregate).iter().map(|ev| {
            let field = crate::bridging::corrects_flag_field(ev);
            exemplar.render("to_json_field", &[("\"tmpl_field_name\"", naming::ruby_inspect_string(&field)), ("tmpl_json_value_placeholder()", format!("crate::kernel::Json::Bool(self.{field})"))])
        }));
    }
    let field_block = field_exprs.iter().map(|f| format!("        {f}")).collect::<Vec<_>>().join("\n");

    format!("{}\n", exemplar.render("to_json_flat", &[("TmplFlatType2", struct_name.to_string()), ("tmpl_to_json_field_block()", field_block)]))
}

/// Command args structs only: an absent optional argument is absent from the event payload, as in
/// Ruby. Re-reads the dense field block so the two forms cannot disagree about a field.
pub fn emit_to_json_flat_sparse(exemplar: &Exemplar, struct_name: &str, attributes: &[Json], value_objects_by_name: &HashMap<String, &Json>) -> String {
    let dense = emit_to_json_flat(exemplar, struct_name, attributes, value_objects_by_name, false, &[], None);
    let open = "vec![\n";
    let start = dense.find(open).map(|i| i + open.len()).expect("to_json_flat renders a vec! literal");
    let end = dense[start..].find("        ])").map(|i| start + i).expect("to_json_flat closes its vec! literal");
    let field_block = dense[start..end].trim_end_matches('\n').to_string();
    format!("{}\n", exemplar.render("to_json_flat_sparse", &[("TmplFlatType3", struct_name.to_string()), ("tmpl_to_json_field_block_sparse()", field_block)]))
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

            let record_optional_list = list && aggregate.map(|a| crate::shared::list_attr_creation_optional(a, crate::attr::name(attr), value_objects_by_name)).unwrap_or(false);
            let list_is_optional = if aggregate.is_some() { record_optional_list } else { crate::attr::optional(attr) };
            let field_optional = optional || crate::attr::optional(attr);

            let rhs = if list && list_is_optional {
                let mapper = list_element_from_json_mapper(struct_name, &key, attr, value_objects_by_name);
                let array_error = json_type_error(struct_name, &key, "an array");
                format!(
                    "match v.get({}) {{ Some(&crate::kernel::Json::Null) | None => None, Some(x) => Some(x.as_array().ok_or_else(|| {array_error})?.iter().map({mapper}).collect::<Result<Vec<_>, crate::kernel::Refusal>>()?), }}",
                    naming::ruby_inspect_string(&key)
                )
            } else if list {
                let mapper = list_element_from_json_mapper(struct_name, &key, attr, value_objects_by_name);
                format!(
                    "match v.get({}).and_then(crate::kernel::Json::as_array) {{ Some(items) => items.iter().map({mapper}).collect::<Result<Vec<_>, crate::kernel::Refusal>>()?, None => Vec::new(), }}",
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
    // `corrects` flag fields: see `emit_to_json_flat`.
    if let Some(aggregate) = aggregate {
        for ev in crate::bridging::correctable_event_names(aggregate) {
            let field = crate::bridging::corrects_flag_field(&ev);
            let ident = naming::rust_ident_field(&field);
            let rhs = format!(
                "match v.require({}, {})? {{ crate::kernel::Json::Bool(b) => *b, _ => return Err({}) }}",
                naming::ruby_inspect_string(&field),
                naming::ruby_inspect_string(struct_name),
                json_type_error(struct_name, &field, "a boolean")
            );
            field_exprs.push(exemplar.render("field_assignment", &[("tmpl_ident", ident), ("tmpl_rhs_placeholder()", rhs)]));
        }
    }

    emit_from_json_skeleton(exemplar, struct_name, &field_exprs, "", None)
}

pub fn emit_closed_set_codec(exemplar: &Exemplar, vo: &Json) -> String {
    let name = naming::rust_ident(vo.get("name").and_then(Json::as_str).unwrap_or(""));
    let attributes = vo.get("attributes").map(Json::each).unwrap_or(&[]);
    let sole_attribute = &attributes[0];
    let sole_attribute_name = crate::attr::name(sole_attribute);
    let sole_attribute_type = sole_attribute.get("type").and_then(Json::as_str).unwrap_or("");
    let field_name = naming::rust_field(sole_attribute_name);
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
    // The member list goes over raw; `render_args` quotes and joins it.
    let admitted = format!("[{}]", rows.iter().map(|(_v, raw)| naming::ruby_inspect_string(raw)).collect::<Vec<_>>().join(", "));
    // Same wording as `required_field_expr`, resolved at codegen time from the sole field.
    let null_message = format!("{type_name}.{sole_attribute_name} expects {sole_attribute_type}, got nil");

    exemplar.assemble(
        "closed_set_codec",
        &[
            ("TmplKind", name),
            ("\"tmpl_field_name\"", naming::ruby_inspect_string(&field_name)),
            ("\"tmpl_closed_set_type\"", naming::ruby_inspect_string(&type_name)),
            ("[\"tmpl_closed_set_member_a\"]", admitted),
            ("\"tmpl_null_field_message\"", naming::ruby_inspect_string(&null_message)),
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
                Some("Float") => format!("crate::kernel::Json::Float(self.{ident})"),
                Some("TrueClass" | "FalseClass") => format!("crate::kernel::Json::Bool(self.{ident})"),
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
    emit_extract_id_shaped(exemplar, aggregate, "extract_id", "to_id_component")
}

/// `extract_id` minted as `extract_id_lenient` on `to_id_component_lenient`; entity addressing
/// only, never a root aggregate's hydrate.
pub fn emit_extract_id_lenient(exemplar: &Exemplar, entity: &Json) -> String {
    emit_extract_id_shaped(exemplar, entity, "extract_id_lenient", "to_id_component_lenient")
}

fn emit_extract_id_shaped(exemplar: &Exemplar, aggregate: &Json, method_name: &str, coercion: &str) -> String {
    let name = naming::rust_ident(aggregate.get("name").and_then(Json::as_str).unwrap_or(""));
    let identified_by: Vec<String> = aggregate.get("identified_by").map(Json::each).unwrap_or(&[]).iter().map(Json::to_s).collect();
    let reference_key = crate::hecks_naming::snake(aggregate.get("name").and_then(Json::as_str).unwrap_or(""));

    // `tmpl_id_coercion` is also set per tier1 entry: `compose` checks the nested `TIER1_LINE`
    // slot for leftover placeholders before the outer text is substituted.
    let tier1_subs: Vec<Vec<(&str, String)>> = identified_by
        .iter()
        .enumerate()
        .map(|(i, path)| vec![("\"tmpl_path\"", naming::ruby_inspect_string(path)), ("c0", format!("c{i}")), ("tmpl_id_coercion", coercion.to_string())])
        .collect();

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
            ("tmpl_extract_id_name", method_name.to_string()),
            ("tmpl_id_coercion", coercion.to_string()),
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
