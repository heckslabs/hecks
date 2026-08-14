//! Port of `rust/project/reference_specs.rb` — read that file's own
//! header comments in full; this mirrors its algorithm directly,
//! function for function.

use crate::json::Json;

#[derive(Clone)]
pub struct ReferenceSpec {
    pub field: String,
    pub as_name: String,
    pub target: String,
}

pub fn reference_specs(domain_name: &str, attributes: &[Json]) -> Vec<ReferenceSpec> {
    attributes
        .iter()
        .filter_map(|attr| {
            let target = crate::naming::reference_target(crate::attr::type_name(attr))?;
            let field = crate::attr::name(attr).to_string();
            let as_name = field.strip_suffix("_id").map(str::to_string).unwrap_or_else(|| field.clone());
            Some(ReferenceSpec { field, as_name, target: format!("{domain_name}::{target}") })
        })
        .collect()
}

pub fn emit_reference_spec(spec: &ReferenceSpec) -> String {
    format!(
        "crate::kernel::ReferenceSpec {{ field: {}, as_name: {}, target: {} }}",
        crate::naming::ruby_inspect_string(&spec.field),
        crate::naming::ruby_inspect_string(&spec.as_name),
        crate::naming::ruby_inspect_string(&spec.target)
    )
}

pub fn emit_reference_specs_literal(specs: &[ReferenceSpec]) -> String {
    if specs.is_empty() {
        return "&[]".to_string();
    }
    format!("&[{}]", specs.iter().map(emit_reference_spec).collect::<Vec<_>>().join(", "))
}
