//! Reads of the domain IR the query rows are built from: attribute facts, the field kind a dotted
//! path lands on, and the `where` hop plan through references.

use crate::kernel::Json;
use std::collections::HashMap;

/// The aggregates (or value objects) of one domain by bare name.
pub type ByName<'a> = HashMap<String, &'a Json>;

/// What a queried field reduces to, the question every comparator and `order_by` asks.
#[derive(PartialEq, Eq, Clone, Copy)]
pub enum Kind {
    Text,
    Number,
    Other,
    Unknown,
}

/// A key's value, with an explicit null read as absent, as the generator reads the IR.
pub fn field<'a>(object: &'a Json, key: &str) -> Option<&'a Json> {
    object.get(key).filter(|value| !matches!(value, Json::Null))
}

/// The items of a list-valued key, or none.
pub fn items<'a>(object: &'a Json, key: &str) -> &'a [Json] {
    field(object, key).and_then(Json::as_array).unwrap_or(&[])
}

/// A scalar read as Ruby's `to_s` would print it; anything else is empty.
pub fn text(value: &Json) -> String {
    match value {
        Json::Str(text) => text.clone(),
        Json::Bool(flag) => flag.to_string(),
        Json::Num(number, _) if number.fract() == 0.0 => format!("{}", *number as i64),
        Json::Num(number, _) => number.to_string(),
        _ => String::new(),
    }
}

/// The text under `key`, empty when absent.
pub fn text_of(object: &Json, key: &str) -> String {
    field(object, key).map(text).unwrap_or_default()
}

/// An attribute's name.
pub fn name(attribute: &Json) -> &str {
    field(attribute, "name")
        .and_then(Json::as_str)
        .unwrap_or("")
}

/// An attribute's declared type name.
pub fn type_name(attribute: &Json) -> &str {
    field(attribute, "type")
        .and_then(Json::as_str)
        .unwrap_or("")
}

/// Whether the attribute holds a list.
pub fn is_list(attribute: &Json) -> bool {
    matches!(field(attribute, "list"), Some(Json::Bool(true)))
}

/// Whether a type name is `Reference<X>`.
pub fn is_reference(type_name: &str) -> bool {
    type_name.starts_with("Reference<")
}

fn reference_target(type_name: &str) -> Option<&str> {
    type_name.strip_prefix("Reference<")?.strip_suffix('>')
}

/// A domain's items keyed by their `name`.
pub fn by_name<'a>(domain: &'a Json, key: &str) -> ByName<'a> {
    items(domain, key)
        .iter()
        .map(|item| (text_of(item, "name"), item))
        .collect()
}

enum PathEnd<'a> {
    Type(&'a str),
    HeadList,
    Broken,
}

fn path_end<'a>(aggregate: &'a Json, path: &str, objects: &ByName<'a>) -> PathEnd<'a> {
    let mut segments = path.split('.');
    let head = segments.next().unwrap_or("");
    let Some(attribute) = items(aggregate, "attributes")
        .iter()
        .find(|a| name(a) == head)
    else {
        return PathEnd::Broken;
    };
    if is_list(attribute) {
        return PathEnd::HeadList;
    }
    let mut current = type_name(attribute);
    for segment in segments {
        let member = objects
            .get(current)
            .and_then(|vo| items(vo, "attributes").iter().find(|a| name(a) == segment));
        match member {
            Some(member) if !is_list(member) => current = type_name(member),
            _ => return PathEnd::Broken,
        }
    }
    PathEnd::Type(current)
}

/// Classifies `path` from `aggregate`: the lifecycle field is text; otherwise the walk's end.
pub fn kind_of(aggregate: &Json, path: &str, objects: &ByName) -> Kind {
    let head = path.split('.').next().unwrap_or("");
    let lifecycle = field(aggregate, "lifecycle")
        .and_then(|l| field(l, "field"))
        .map(text);
    if lifecycle.as_deref() == Some(head) {
        return if path.contains('.') {
            Kind::Unknown
        } else {
            Kind::Text
        };
    }
    match path_end(aggregate, path, objects) {
        PathEnd::HeadList => Kind::Other,
        PathEnd::Broken => Kind::Unknown,
        PathEnd::Type(type_name) => type_kind(type_name, objects),
    }
}

fn type_kind(type_name: &str, objects: &ByName) -> Kind {
    if is_reference(type_name) {
        return Kind::Text;
    }
    match type_name {
        "String" => Kind::Text,
        "Integer" | "Float" => Kind::Number,
        "TrueClass" | "FalseClass" => Kind::Other,
        other => objects
            .get(other)
            .map_or(Kind::Unknown, |vo| collapse_kind(vo, objects)),
    }
}

fn collapse_kind(vo: &Json, objects: &ByName) -> Kind {
    let attributes = items(vo, "attributes");
    if attributes
        .iter()
        .any(|a| matches!(type_name(a), "Integer" | "Float"))
    {
        return Kind::Number;
    }
    match attributes {
        [only] => type_kind(type_name(only), objects),
        _ => Kind::Other,
    }
}

/// A `/` hop chain through reference attributes to aggregates the domain declares.
pub struct HopPlan<'a> {
    pub via_field: String,
    pub target: String,
    pub through: Vec<(String, String)>,
    pub final_aggregate: &'a Json,
    pub inner_field: String,
}

const HOP_CHAIN_LIMIT: usize = 8;

/// Plans `field` as a hop chain, or `None` when it is not one.
pub fn hop_plan<'a>(
    aggregate: &'a Json,
    path: &str,
    aggregates: &ByName<'a>,
) -> Option<HopPlan<'a>> {
    let segments: Vec<&str> = path.split('/').collect();
    if segments.len() < 2 || segments.len() - 1 > HOP_CHAIN_LIMIT {
        return None;
    }
    let mut steps: Vec<(String, String)> = Vec::new();
    let mut current = aggregate;
    for segment in &segments[..segments.len() - 1] {
        let via = items(current, "attributes")
            .iter()
            .find(|a| name(a) == *segment)?;
        let target_name = reference_target(type_name(via))?;
        current = *aggregates.get(target_name)?;
        steps.push(((*segment).to_string(), target_name.to_string()));
    }
    let (via_field, target) = steps.remove(0);
    let inner_field = segments[segments.len() - 1].to_string();
    Some(HopPlan {
        via_field,
        target,
        through: steps,
        final_aggregate: current,
        inner_field,
    })
}
