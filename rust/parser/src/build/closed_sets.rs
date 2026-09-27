//! Mirrors `AttributeCollector#synthesise_closed_set`: an inline `one_of("a", "b")` attribute
//! becomes a closed-set value object named `Naming.pascal(attribute_name)`.

use crate::build::naming;
use crate::ir;

/// Builds the closed-set value object for `field_name` with one member per value.
///
/// Only `AggregateBuilder#build` keeps the result; command, query, value-object and port
/// builders discard it and keep the derived type name.
pub fn synthesize(field_name: &str, values: &[String]) -> ir::ValueObject {
    let type_name = naming::pascal(field_name);
    ir::ValueObject {
        name: type_name,
        attributes: vec![ir::Attribute {
            name: "value".to_string(),
            type_name: "String".to_string(),
            ..Default::default()
        }],
        invariants: Vec::new(),
        closed_set: true,
        members: values
            .iter()
            .map(|value| vec![("value".to_string(), crate::ruby_value::Value::Str(value.clone()))])
            .collect(),
    }
}
