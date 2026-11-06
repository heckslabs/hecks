//! A named query's argument gate (ADR 0037), read from the IR: a bare scalar argument is
//! shape-checked, and a value-object argument is built and invariant-checked, then dropped.
//! `rust/codegen/src/queries.rs` `query_arg_checks` writes the same gate as Rust source.
//!
//! A value object is interpreted when every attribute is a required, plain scalar; anything wider
//! (a list, a nested or closed-set object, an optional or defaulted field, `admits`) is not read
//! here, and the query keeps the generated gate.

use super::ast;
use super::shape::{self, field, items, text_of, ByName};
use crate::kernel::refusal_wording::{
    InvariantViolationValueObjectInvariantArgs, TypeMismatchPatternMismatchArgs,
    UnknownArgumentUnknownArgsArgs,
};
use crate::kernel::{pattern, EvalContext, Expr, Field, Fielded, Json, NoFields, Refusal, Value};

const SCALAR_ARG_TYPES: [&str; 3] = ["String", "Integer", "Float"];

struct Member {
    name: String,
    scalar: &'static str,
    pattern: Option<String>,
}

/// A value object, as far as an argument gate needs it.
pub struct ObjectSpec {
    name: String,
    members: Vec<Member>,
    invariants: Vec<(String, Expr)>,
}

/// One checked argument of a query.
pub enum ArgCheck {
    Scalar {
        key: String,
        owner: String,
        type_name: String,
    },
    Object {
        key: String,
        type_name: String,
        sole: Option<String>,
        spec: ObjectSpec,
    },
}

fn scalar_of(type_name: &str) -> Option<&'static str> {
    ["String", "Integer", "Float", "TrueClass", "FalseClass"]
        .into_iter()
        .find(|t| *t == type_name)
}

fn member_of(attribute: &Json) -> Option<Member> {
    let plain = ["default", "admits", "relationship"]
        .iter()
        .all(|key| field(attribute, key).is_none());
    let flat = !shape::is_list(attribute)
        && !matches!(field(attribute, "optional"), Some(Json::Bool(true)));
    let scalar = scalar_of(shape::type_name(attribute))?;
    let pattern = field(attribute, "pattern").map(shape::text);
    (plain && flat && (pattern.is_none() || scalar == "String")).then(|| Member {
        name: shape::name(attribute).to_string(),
        scalar,
        pattern,
    })
}

fn object_spec(vo: &Json) -> Option<ObjectSpec> {
    if matches!(field(vo, "closed_set"), Some(Json::Bool(true))) {
        return None;
    }
    let members = items(vo, "attributes")
        .iter()
        .map(member_of)
        .collect::<Option<Vec<_>>>()?;
    let invariants = items(vo, "invariants")
        .iter()
        .map(|inv| {
            Some((
                text_of(inv, "description"),
                ast::parse(field(inv, "ast")?).ok()?,
            ))
        })
        .collect::<Option<Vec<_>>>()?;
    Some(ObjectSpec {
        name: text_of(vo, "name"),
        members,
        invariants,
    })
}

/// The checks one argument carries (none for a list, a reference or an unchecked type), or
/// `None` when it is a value object this reading does not cover.
fn check_for(attribute: &Json, owner: &str, objects: &ByName) -> Option<Vec<ArgCheck>> {
    if shape::is_list(attribute) || field(attribute, "relationship").is_some() {
        return Some(Vec::new());
    }
    let (key, type_name) = (
        shape::name(attribute).to_string(),
        shape::type_name(attribute),
    );
    let Some(vo) = objects.get(type_name) else {
        let scalar = SCALAR_ARG_TYPES.contains(&type_name);
        let check = ArgCheck::Scalar {
            key,
            owner: owner.to_string(),
            type_name: type_name.to_string(),
        };
        return Some(if scalar { vec![check] } else { Vec::new() });
    };
    let sole = match items(vo, "attributes") {
        [only] => Some(shape::name(only).to_string()),
        _ => None,
    };
    let spec = object_spec(vo)?;
    Some(vec![ArgCheck::Object {
        key,
        type_name: type_name.to_string(),
        sole,
        spec,
    }])
}

/// The gate for `query` on aggregate `owner`, or `None` when it needs the generated one.
pub fn checks_for(query: &Json, owner: &str, objects: &ByName) -> Option<Vec<ArgCheck>> {
    let mut checks = Vec::new();
    for attribute in items(query, "attributes") {
        checks.extend(check_for(attribute, owner, objects)?);
    }
    Some(checks)
}

/// Runs a query's gate over its call arguments.
pub fn run(checks: &[ArgCheck], args: &Json) -> Result<(), Refusal> {
    for check in checks {
        match check {
            ArgCheck::Scalar {
                key,
                owner,
                type_name,
            } => {
                if let Some(x) = args.get(key) {
                    x.expect_scalar_shape(owner, key, type_name)?;
                }
            }
            ArgCheck::Object {
                key,
                type_name,
                sole,
                spec,
            } => {
                if let Some(x) = args.get(key) {
                    let offered = match sole {
                        Some(sole) => x.coerce_single_field(sole),
                        None => x.expect_value_object_shape(key, type_name)?.clone(),
                    };
                    spec.build(&offered)?.check()?;
                }
            }
        }
    }
    Ok(())
}

/// A value object built from an offered object.
struct Built<'a> {
    spec: &'a ObjectSpec,
    values: Vec<Value>,
}

impl ObjectSpec {
    fn build(&self, v: &Json) -> Result<Built<'_>, Refusal> {
        if !matches!(v, Json::Object(_)) {
            let message = format!("{} expects an object, got {}", self.name, v.inspect());
            return Err(Refusal::TypeMismatch(message));
        }
        let declared: Vec<&str> = self.members.iter().map(|m| m.name.as_str()).collect();
        let unknown = v.unknown_keys(&declared);
        if !unknown.is_empty() {
            let unknown: Vec<&str> = unknown.iter().map(String::as_str).collect();
            let args = UnknownArgumentUnknownArgsArgs {
                command: &self.name,
                unknown: &unknown,
                declared: &declared,
            };
            return Err(Refusal::UnknownArgument(args.render_args()));
        }
        let values = self
            .members
            .iter()
            .map(|m| self.read(m, v))
            .collect::<Result<Vec<_>, _>>()?;
        Ok(Built { spec: self, values })
    }

    fn read(&self, member: &Member, v: &Json) -> Result<Value, Refusal> {
        let (owner, key, expected) = (&self.name, &member.name, member.scalar);
        let x = v.get(key).ok_or_else(|| {
            Refusal::TypeMismatch(format!("{owner}.{key} expects {expected}, got nil"))
        })?;
        let wrong = || {
            Refusal::TypeMismatch(format!(
                "{owner}.{key} expects {expected}, got {}",
                x.describe()
            ))
        };
        match expected {
            "String" => x
                .as_str()
                .map(|s| Value::Str(s.to_string()))
                .ok_or_else(wrong),
            "Float" => x.as_f64().map(Value::Float).ok_or_else(wrong),
            "Integer" => x.as_i64().map(Value::Int).ok_or_else(|| match x {
                Json::Num(n, _)
                    if n.is_finite() && n.fract() == 0.0 && n.abs() >= 9.223_372_036_854_776e18 =>
                {
                    Refusal::TypeMismatch(format!(
                        "{owner}.{key} must fit in a 64-bit integer, got {}",
                        x.describe()
                    ))
                }
                _ => wrong(),
            }),
            _ => x.as_bool().map(Value::Bool).ok_or_else(wrong),
        }
    }
}

impl Fielded for Built<'_> {
    fn field(&self, name: &str) -> Option<Field<'_>> {
        let at = self.spec.members.iter().position(|m| m.name == name)?;
        Some(Field::Value(self.values[at].clone()))
    }

    fn as_scalar(&self) -> Option<Value> {
        match self.values.as_slice() {
            [only] => Some(only.clone()),
            _ => None,
        }
    }
}

impl Built<'_> {
    fn to_json(&self) -> Json {
        let mut fields: Vec<(String, Json)> = Vec::new();
        for (member, value) in self.spec.members.iter().zip(&self.values) {
            let json = match value {
                Value::Str(s) => Json::Str(s.clone()),
                Value::Int(n) => Json::int(*n),
                Value::Float(n) => Json::Float(*n),
                Value::Bool(b) => Json::Bool(*b),
                _ => Json::Null,
            };
            fields.push((member.name.clone(), json));
        }
        fields.sort_by(|a, b| a.0.cmp(&b.0));
        Json::Object(fields)
    }

    fn check(&self) -> Result<(), Refusal> {
        for (member, value) in self.spec.members.iter().zip(&self.values) {
            match (&member.pattern, value) {
                (Some(pat), Value::Str(s)) if !pattern::matches_whole(pat, s) => {
                    let offered = format!("{s:?}");
                    let args = TypeMismatchPatternMismatchArgs {
                        r#type: &self.spec.name,
                        field: &member.name,
                        pattern: pat,
                        offered: &offered,
                    };
                    return Err(Refusal::TypeMismatch(args.render_args()));
                }
                _ => {}
            }
        }
        self.spec
            .invariants
            .iter()
            .try_for_each(|(description, expr)| self.invariant(description, expr))
    }

    fn invariant(&self, description: &str, expr: &Expr) -> Result<(), Refusal> {
        let ctx = EvalContext {
            args: &NoFields,
            instance: self,
        };
        if crate::kernel::interpret(expr, &ctx)?.truthy() {
            return Ok(());
        }
        let offered = self.to_json().to_json_string();
        let args = InvariantViolationValueObjectInvariantArgs {
            name: &self.spec.name,
            description,
            offered: &offered,
        };
        Err(Refusal::InvariantViolation(args.render_args()))
    }
}
