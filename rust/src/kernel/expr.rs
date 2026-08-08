// HAND-WRITTEN, ONCE, GENERIC — a direct structural port of
// `Hecksagain::Bluebook::Expression::Evaluator` and `::Resolver`
// (docs/guides/running-a-runtime.md's "The expression grammar"), not a
// reimplementation of parsing. bin/project_rust parses real canonical
// `given`/`ensures`/invariant text with the REAL Ruby parser and emits
// `Expr` DATA literals from that AST; the only thing written here is
// INTERPRETATION — `Evaluator#interpret`/`Resolver#interpret`, ported.
//
// This is what replaces compiling each expression to bespoke Rust
// boolean source: one generic `interpret()` walks ANY expression this
// grammar can produce, driven by data a generator emits, the same way
// `CommandInterpreter` is one Ruby method that walks any command's IR
// rather than one method per command shape.

use super::Refusal;

// ── VALUE — the dynamic runtime value an expression evaluates to.
// Mirrors what Ruby's `Resolver#interpret` can return (Integer/Float/
// String/true/false/nil), plus one addition: `List(usize)`. Real corpus
// expressions only ever ask `.size`/`.empty?` of a list-typed field,
// never index into its elements by expression — so a list field
// surfaces as its length, not its contents.
#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Int(i64),
    Float(f64),
    Str(String),
    Bool(bool),
    List(usize),
    Nil,
}

impl Value {
    /// Ruby's `Evaluator.truthy?`: `!value.nil? && value != false`.
    pub fn truthy(&self) -> bool {
        !matches!(self, Value::Nil | Value::Bool(false))
    }

    fn numeric(&self) -> Option<f64> {
        match self {
            Value::Int(i) => Some(*i as f64),
            Value::Float(f) => Some(*f),
            _ => None,
        }
    }
}

// ── FIELD / FIELDED — the lookup surface every generated struct (value
// object or aggregate record, and command args structs) implements. A
// dotted `Lookup` path walks this: the first segment resolves against
// args-then-instance (see `lookup`, below); every later segment walks a
// `Field::Nested` chain. Implementations are mechanical and generated —
// one match arm per real attribute, the same shape for every type — not
// bespoke per command.
pub enum Field<'a> {
    Value(Value),
    Nested(&'a dyn Fielded),
}

pub trait Fielded {
    fn field(&self, name: &str) -> Option<Field<'_>>;
}

/// A `Fielded` with nothing in it — used where Ruby's own `attrs` is `{}`
/// too, i.e. a value object checking its own invariants (no command
/// arguments are in scope, only the value object's own fields as `state`).
pub struct NoFields;
impl Fielded for NoFields {
    fn field(&self, _name: &str) -> Option<Field<'_>> {
        None
    }
}

/// `args.merge(old: old)` — `CommandRules::Admissibility#enforce_ensures`,
/// read directly. `ensures` runs with the SAME `attrs` a `given` would,
/// plus one merged key: `old`, the instance as it stood before
/// `apply_mutations` ran. `old` is checked first, the same order Ruby's
/// own `Hash#merge` gives it precedence in — a real argument named `old`
/// would be shadowed the identical way in both runtimes, not just this
/// one.
pub struct WithOld<'a> {
    pub args: &'a dyn Fielded,
    pub old: &'a dyn Fielded,
}

impl<'a> Fielded for WithOld<'a> {
    fn field(&self, name: &str) -> Option<Field<'_>> {
        if name == "old" {
            return Some(Field::Nested(self.old));
        }
        self.args.field(name)
    }
}

// ── COMPARISON — mirrors `Evaluator::Operator` exactly: six comparison
// operators reduced to two primitives (`less_than`, `equal`) combined
// with a negation, rather than six separate code paths.
#[derive(Debug, Clone, Copy)]
pub struct Comparison {
    pub less_than: bool,
    pub equal: bool,
    pub negated: bool,
}

// ── EXPR — the full Evaluator + Resolver AST as one recursive Rust enum.
// Every variant corresponds to exactly one real Ruby node type:
// Evaluator::{Or,And,Not,Compare,Include,Resolve} and Resolver::
// {IntegerLiteral,FloatLiteral,StringLiteral,BoolLiteral,NilLiteral,
// Addition,SignTest,Empty,ToS,Modulo,Size,Lookup}. `Resolve` itself
// doesn't need its own variant — Ruby's `Resolve` is just "interpret the
// wrapped Resolver node, then check truthiness," and every `Expr` variant
// below already produces a `Value` that `interpret`'s callers can check
// for truthiness directly.
// Not every domain's `given`/`ensures`/invariant text exercises every
// node this grammar admits — a variant going unconstructed for one
// domain is expected, not a sign of dead code to prune.
#[derive(Debug, Clone)]
#[allow(dead_code)]
pub enum Expr {
    Or(Box<Expr>, Box<Expr>),
    And(Box<Expr>, Box<Expr>),
    Not(Box<Expr>),
    Compare { op: Comparison, left: Box<Expr>, right: Box<Expr> },
    Include { haystack: Box<Expr>, needle: Box<Expr> },
    Int(i64),
    Float(f64),
    Str(String),
    Bool(bool),
    Nil,
    Add(Box<Expr>, Box<Expr>),
    SignTest { op: Comparison, receiver: Box<Expr> },
    Empty(Box<Expr>),
    ToS(Box<Expr>),
    Modulo { receiver: Box<Expr>, divisor: Box<Expr> },
    Size(Box<Expr>),
    Lookup(&'static str),
}

/// `state`/`attrs` from `Evaluator.call(expr, state, attrs)` — `args` is
/// checked first for every `Lookup`, `instance` second, matching
/// `Resolver#fetch` exactly. Pass `&NoFields` for whichever side Ruby's
/// own call site would have passed `{}` for.
pub struct EvalContext<'a> {
    pub args: &'a dyn Fielded,
    pub instance: &'a dyn Fielded,
}

pub fn interpret(expr: &Expr, ctx: &EvalContext) -> Result<Value, Refusal> {
    use Expr::*;
    Ok(match expr {
        Or(l, r) => Value::Bool(interpret(l, ctx)?.truthy() || interpret(r, ctx)?.truthy()),
        And(l, r) => Value::Bool(interpret(l, ctx)?.truthy() && interpret(r, ctx)?.truthy()),
        Not(n) => Value::Bool(!interpret(n, ctx)?.truthy()),
        Compare { op, left, right } => {
            let l = interpret(left, ctx)?;
            let r = interpret(right, ctx)?;
            Value::Bool(apply(op, &l, &r)?)
        }
        // Real corpus only ever calls `.include?` with a String haystack
        // (INCLUDE_HAYSTACKS also admits Array in Ruby; not generated yet
        // — no real given/ensures/invariant in either example domain
        // exercises the Array case).
        Include { haystack, needle } => match (interpret(haystack, ctx)?, interpret(needle, ctx)?) {
            (Value::Str(h), Value::Str(n)) => Value::Bool(h.contains(&n)),
            (h, n) => return Err(eval_error(format!("include? on {h:?} with {n:?} — Array haystacks not generated yet"))),
        },
        Int(v) => Value::Int(*v),
        Float(v) => Value::Float(*v),
        Str(v) => Value::Str(v.clone()),
        Bool(v) => Value::Bool(*v),
        Nil => Value::Nil,
        Add(l, r) => add(&interpret(l, ctx)?, &interpret(r, ctx)?)?,
        // A sign test is sugar for comparing the receiver against literal
        // 0 — no int/float distinction needed here the way a STATIC
        // compiler would need one, because `apply`/`less_than` below
        // compare through `Value::numeric` (`f64`) uniformly regardless
        // of which literal type carries the zero.
        SignTest { op, receiver } => {
            let v = interpret(receiver, ctx)?;
            require_number(&v, "sign test")?;
            Value::Bool(apply(op, &v, &Value::Int(0))?)
        }
        Empty(r) => match interpret(r, ctx)? {
            Value::Str(s) => Value::Bool(s.is_empty()),
            Value::List(n) => Value::Bool(n == 0),
            v => return Err(eval_error(format!("empty? expects a list or string, got {v:?}"))),
        },
        ToS(r) => match interpret(r, ctx)? {
            Value::Str(s) => Value::Str(s),
            Value::Int(i) => Value::Str(i.to_string()),
            Value::Float(f) => Value::Str(f.to_string()),
            Value::Bool(b) => Value::Str(b.to_string()),
            Value::Nil => Value::Str(String::new()),
            v => return Err(eval_error(format!("to_s expects a scalar, got {v:?}"))),
        },
        Modulo { receiver, divisor } => {
            let r = require_number(&interpret(receiver, ctx)?, "modulo")?.trunc() as i64;
            let d = require_number(&interpret(divisor, ctx)?, "modulo")?.trunc() as i64;
            if d == 0 {
                return Err(eval_error("divided by 0".to_string()));
            }
            Value::Int(r % d)
        }
        Size(r) => match interpret(r, ctx)? {
            Value::Str(s) => Value::Int(s.chars().count() as i64),
            Value::List(n) => Value::Int(n as i64),
            v => return Err(eval_error(format!("size expects a list or string, got {v:?}"))),
        },
        Lookup(path) => lookup(path, ctx)?,
    })
}

/// The algebra itself, on values already resolved — mirrors
/// `Evaluator.apply` exactly: OR the two primitives together, negate if
/// the operator says to.
fn apply(op: &Comparison, lhs: &Value, rhs: &Value) -> Result<bool, Refusal> {
    let lt = op.less_than && less_than(lhs, rhs)?;
    let eq = op.equal && values_equal(lhs, rhs);
    Ok(if op.negated { !(lt || eq) } else { lt || eq })
}

fn less_than(lhs: &Value, rhs: &Value) -> Result<bool, Refusal> {
    match (lhs.numeric(), rhs.numeric()) {
        (Some(l), Some(r)) => Ok(l < r),
        _ => match (lhs, rhs) {
            (Value::Str(l), Value::Str(r)) => Ok(l < r),
            _ => Err(eval_error(format!("comparison of {lhs:?} with {rhs:?} failed"))),
        },
    }
}

fn values_equal(lhs: &Value, rhs: &Value) -> bool {
    match (lhs.numeric(), rhs.numeric()) {
        (Some(l), Some(r)) => l == r,
        _ => lhs == rhs,
    }
}

fn add(lhs: &Value, rhs: &Value) -> Result<Value, Refusal> {
    if let (Value::Int(l), Value::Int(r)) = (lhs, rhs) {
        return Ok(Value::Int(l + r));
    }
    let l = require_number(lhs, "addition")?;
    let r = require_number(rhs, "addition")?;
    Ok(Value::Float(l + r))
}

fn require_number(v: &Value, operation: &str) -> Result<f64, Refusal> {
    v.numeric().ok_or_else(|| eval_error(format!("{operation} expects a number, got {v:?}")))
}

/// `Resolver#fetch`: the first path segment is checked against `attrs`
/// (args) first, `state` (instance) second; every later segment walks a
/// `Field::Nested` chain. An `EvaluationError` in Ruby is not one of the
/// nine real `DOMAIN_REFUSALS` — by construction, canonical text was
/// already validated when the domain booted, so reaching this in the
/// generated Rust means a codegen bug, not a real business refusal.
/// `TypeMismatch` is the closest existing refusal to "this shouldn't be
/// possible if the generator is correct," so it's what this raises,
/// rather than inventing a tenth refusal kind Ruby doesn't have.
fn lookup(path: &str, ctx: &EvalContext) -> Result<Value, Refusal> {
    let mut segments = path.split('.');
    let head = segments.next().unwrap();
    let mut current = ctx
        .args
        .field(head)
        .or_else(|| ctx.instance.field(head))
        .ok_or_else(|| eval_error(format!("cannot resolve {head:?} — no such attribute or argument")))?;

    for seg in segments {
        current = match current {
            Field::Nested(obj) => obj
                .field(seg)
                .ok_or_else(|| eval_error(format!("cannot resolve {seg:?} on {head:?}")))?,
            Field::Value(v) => return Err(eval_error(format!("{path} — cannot look up {seg:?} on scalar {v:?}"))),
        };
    }

    match current {
        Field::Value(v) => Ok(v),
        Field::Nested(_) => Err(eval_error(format!("{path} resolved to an object, not a scalar"))),
    }
}

fn eval_error(message: String) -> Refusal {
    Refusal::TypeMismatch(message)
}
