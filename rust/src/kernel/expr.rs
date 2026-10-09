//! Interprets the `Expr` AST — a structural port of Ruby's
//! `Evaluator`/`Resolver` (docs/implemented/guides/running-a-runtime.md).

use super::Refusal;
use crate::kernel::attribute_shapes::composite;
use crate::kernel::expression_operators::{self, comparison, OperatorCategory};

/// The dynamic runtime value an expression evaluates to — mirrors
/// Ruby's `Resolver#interpret`, plus `List(usize)`: a list field's length.
#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Int(i64),
    Float(f64),
    Str(String),
    Bool(bool),
    List(usize),
    Nil,
    /// A materialised list — distinct from the length-only `List(usize)`
    /// above. Produced by an array literal or `.split`; never used for
    /// `.include?`'s haystack (`expr_emitter.rb`'s `emit_include` rewrites
    /// that shape at codegen time instead).
    Array(Vec<Value>),
}

impl Value {
    /// Ruby's `Evaluator.truthy?`: false only for `Nil`/`Bool(false)`.
    pub fn truthy(&self) -> bool {
        !matches!(self, Value::Nil | Value::Bool(false))
    }

    /// The text of a `Str`, else `None`; a generated `SetProjectedField` arm narrows a
    /// projected scalar to its field's type with one of the `into_*` readers.
    pub fn into_string(self) -> Option<String> {
        match self {
            Value::Str(s) => Some(s),
            _ => None,
        }
    }

    /// The integer of an `Int`, else `None`.
    pub fn into_i64(self) -> Option<i64> {
        match self {
            Value::Int(n) => Some(n),
            _ => None,
        }
    }

    /// The float of a `Float`, else `None`.
    pub fn into_f64(self) -> Option<f64> {
        match self {
            Value::Float(f) => Some(f),
            _ => None,
        }
    }

    /// The boolean of a `Bool`, else `None`.
    pub fn into_bool(self) -> Option<bool> {
        match self {
            Value::Bool(b) => Some(b),
            _ => None,
        }
    }
}

pub enum Field<'a> {
    Value(Value),
    Nested(&'a dyn Fielded),
}

/// The lookup surface every generated struct implements. A dotted
/// `Lookup` resolves its head segment here, then walks `Field::Nested`.
pub trait Fielded {
    fn field(&self, name: &str) -> Option<Field<'_>>;

    /// The bare (undotted) `Lookup` reading of this object — Ruby's
    /// `unwrap_scalar` fallthrough. `DerefNode` overrides to answer its id.
    fn as_scalar(&self) -> Option<Value> {
        None
    }

    /// The elements of a list-typed field, for the enumeration operators
    /// (`.any?`/`.all?`/`.none?`/`.find`). Default `None`, like `as_scalar`.
    fn items(&self, _name: &str) -> Option<Vec<Field<'_>>> {
        None
    }
}

/// A block's own parameter, checked before `rest` (real args/instance) —
/// Ruby's `interpret_with_element` merge order. Nested blocks chain a
/// `Bound` inside a `Bound`, matching Ruby's nested `merge`.
pub struct Bound<'a> {
    pub name: &'a str,
    pub value: Field<'a>,
    pub rest: &'a dyn Fielded,
}

impl<'a> Fielded for Bound<'a> {
    fn field(&self, name: &str) -> Option<Field<'_>> {
        if name == self.name {
            return Some(match &self.value {
                Field::Value(v) => Field::Value(v.clone()),
                Field::Nested(obj) => Field::Nested(*obj),
            });
        }
        self.rest.field(name)
    }

    fn items(&self, name: &str) -> Option<Vec<Field<'_>>> {
        if name == self.name {
            // A bound element is one member, never itself a list.
            return None;
        }
        self.rest.items(name)
    }
}

/// A `Fielded` with nothing in it — Ruby's own `attrs` is `{}` too, e.g.
/// a value object checking its own invariants against only its fields.
pub struct NoFields;
impl Fielded for NoFields {
    fn field(&self, _name: &str) -> Option<Field<'_>> {
        None
    }
}

/// `ensures`'s own `attrs`, plus `old` (pre-mutation instance) merged in
/// and checked first — Ruby's `Hash#merge` precedence, `enforce_ensures`.
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

    fn items(&self, name: &str) -> Option<Vec<Field<'_>>> {
        if name == "old" {
            return None;
        }
        self.args.items(name)
    }
}

/// C2.3 (docs/semantics/bluebook-semantics.md): inside `ensures`, settled
/// state wins over a same-named argument (unlike `given`'s C2.2) — the
/// same drop `enforce_ensures` does, answered lazily per lookup.
pub struct StateFirst<'a> {
    pub args: &'a dyn Fielded,
    pub settled: &'a dyn Fielded,
}

impl<'a> Fielded for StateFirst<'a> {
    fn field(&self, name: &str) -> Option<Field<'_>> {
        if self.settled.field(name).is_some() {
            return None;
        }
        self.args.field(name)
    }

    fn items(&self, name: &str) -> Option<Vec<Field<'_>>> {
        if self.settled.field(name).is_some() {
            return None;
        }
        self.args.items(name)
    }
}

/// An entity command's owning record, exposed as `parent` on the args
/// side (`enforce_givens`/`enforce_ensures`), merged after `old` — Ruby's
/// own `merge` order gives `old` precedence.
pub struct WithParent<'a> {
    pub args: &'a dyn Fielded,
    pub parent: &'a dyn Fielded,
}

impl<'a> Fielded for WithParent<'a> {
    fn field(&self, name: &str) -> Option<Field<'_>> {
        if name == "parent" {
            return Some(Field::Nested(self.parent));
        }
        self.args.field(name)
    }

    fn items(&self, name: &str) -> Option<Vec<Field<'_>>> {
        if name == "parent" {
            return None;
        }
        self.args.items(name)
    }
}

// Re-exported here so generated call sites (`expr_emitter.rb` emits
// `crate::kernel::Comparison { .. }`) keep working unchanged.
pub use comparison::Comparison;

/// The three spellings of one Array-aggregation family, kept as one
/// node with a mode — matching Ruby's `BlockPredicate#mode`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BlockMode {
    All,
    Any,
    None,
}

impl BlockMode {
    /// The operator's own spelling, for the "expects a list" wording
    /// Ruby renders from `"#{node.mode}?"`.
    pub fn ruby_name(&self) -> &'static str {
        match self {
            BlockMode::All => "all?",
            BlockMode::Any => "any?",
            BlockMode::None => "none?",
        }
    }
}

/// The full Evaluator + Resolver AST, one recursive enum — each variant
/// is exactly one Ruby node type. An unconstructed variant for one
/// domain is expected, not dead code to prune.
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
    /// `receiver.any?`/`.all?`/`.none? { |param| predicate }` —
    /// evaluated once per element with `param` bound (see `Bound`).
    BlockPredicate { mode: BlockMode, receiver: Box<Expr>, param: &'static str, predicate: Box<Expr> },
    /// `receiver.find { |param| predicate }.a.b` — first accepted
    /// element, projected through `path`, or nil when nothing matches.
    Find { receiver: Box<Expr>, param: &'static str, predicate: Box<Expr>, path: &'static [&'static str] },
    /// `[a, b, c]` — a leaf like `Int`/`Str`/`Nil` above, not an
    /// operator, so `interpret` handles it directly, not via
    /// `dispatch_operator`.
    Array(Vec<Expr>),
    /// `receiver.match?(/pattern/flags)` — `pattern` is a real
    /// Ruby-Regexp source, taken as-is between the slashes.
    MatchesRegex { receiver: Box<Expr>, pattern: String, flags: String },
    /// `receiver.present?` / `.blank?` — one node for the pair,
    /// `negated` distinguishing them (`.blank?` is `.present?` negated).
    Presence { receiver: Box<Expr>, negated: bool },
    /// `receiver.set?` / `.unset?` — narrower than `Presence`: only
    /// `!receiver.is_nil()`. An assigned-but-empty value is `.set?`,
    /// unlike `Presence`'s Rails-standard emptiness reading.
    Assignment { receiver: Box<Expr>, negated: bool },
    /// `receiver.split("SEP")` — `Resolver::Split`. Produces a real
    /// `Value::Array`, not `Value::List` — see that variant's own header.
    Split { receiver: Box<Expr>, separator: String },
    /// `receiver.start_with?("prefix")` — `Resolver::StartsWith`.
    StartsWith { receiver: Box<Expr>, substring: String },
    /// `receiver.end_with?("suffix")` — `Resolver::EndsWith`.
    EndsWith { receiver: Box<Expr>, substring: String },
    /// `receiver.first` — `Resolver::First`.
    First(Box<Expr>),
    /// `receiver.last` — `Resolver::Last`.
    Last(Box<Expr>),
}

/// `args`/`instance` from `Evaluator.call` — `args` is checked first for
/// every `Lookup`, matching `Resolver#fetch`. Pass `&NoFields` for `{}`.
pub struct EvalContext<'a> {
    pub args: &'a dyn Fielded,
    pub instance: &'a dyn Fielded,
}

/// Leaves (literals, `Lookup`) have no `OperatorCategory`, so they're
/// handled directly; everything else routes through `dispatch_operator`.
pub fn interpret(expr: &Expr, ctx: &EvalContext) -> Result<Value, Refusal> {
    use Expr::*;
    match expr {
        Int(v) => Ok(Value::Int(*v)),
        Float(v) => Ok(Value::Float(*v)),
        Str(v) => Ok(Value::Str(v.clone())),
        Bool(v) => Ok(Value::Bool(*v)),
        Nil => Ok(Value::Nil),
        Lookup(path) => lookup(path, ctx),
        Array(elements) => Ok(Value::Array(elements.iter().map(|e| interpret(e, ctx)).collect::<Result<Vec<_>, _>>()?)),
        _ => dispatch_operator(category_of(expr), expr, ctx),
    }
}

/// Which `OperatorCategory` a non-leaf `Expr` variant belongs to — a
/// hand-written association `interpret` never calls for a leaf, hence
/// the `unreachable!` there rather than a wrong category.
fn category_of(expr: &Expr) -> OperatorCategory {
    use Expr::*;
    match expr {
        Or(..) | And(..) | Not(..) => OperatorCategory::Logical,
        Include { .. } => OperatorCategory::Membership,
        Compare { .. } => OperatorCategory::Comparison,
        Add(..) | Modulo { .. } => OperatorCategory::Arithmetic,
        SignTest { .. } => OperatorCategory::SignTest,
        Empty(..) | Size(..) => OperatorCategory::Sized,
        ToS(..) => OperatorCategory::ToString,
        BlockPredicate { .. } | Find { .. } => OperatorCategory::Enumeration,
        MatchesRegex { .. } => OperatorCategory::PatternMatch,
        Presence { .. } | Assignment { .. } => OperatorCategory::Presence,
        Split { .. } | StartsWith { .. } | EndsWith { .. } => OperatorCategory::Text,
        First(..) | Last(..) => OperatorCategory::Positional,
        Int(..) | Float(..) | Str(..) | Bool(..) | Nil | Lookup(..) | Array(..) => {
            unreachable!("interpret's own leaf arms handle these before category_of is ever called")
        }
    }
}

/// Exhaustive over `OperatorCategory`, no wildcard `_ =>` arm: adding or
/// removing a variant (hecks project_kernel_capabilities) stops this
/// compiling until a matching arm exists. Never add one back — it would
/// silently route a new category to the wrong operator file.
fn dispatch_operator(category: OperatorCategory, expr: &Expr, ctx: &EvalContext) -> Result<Value, Refusal> {
    use expression_operators::*;
    match category {
        OperatorCategory::Logical => logical::interpret(expr, ctx),
        OperatorCategory::Membership => membership::interpret(expr, ctx),
        OperatorCategory::Comparison => comparison::interpret(expr, ctx),
        OperatorCategory::Arithmetic => match expr {
            Expr::Add(..) => arithmetic::add(expr, ctx),
            Expr::Modulo { .. } => arithmetic::modulo(expr, ctx),
            _ => Err(Refusal::TypeMismatch(format!("dispatch_operator(Arithmetic, ..) called with {expr:?} — a router bug"))),
        },
        OperatorCategory::SignTest => sign_test::interpret(expr, ctx),
        OperatorCategory::Sized => match expr {
            Expr::Empty(..) => sized::empty(expr, ctx),
            Expr::Size(..) => sized::size(expr, ctx),
            _ => Err(Refusal::TypeMismatch(format!("dispatch_operator(Sized, ..) called with {expr:?} — a router bug"))),
        },
        OperatorCategory::ToString => to_string::interpret(expr, ctx),
        OperatorCategory::Enumeration => enumeration::interpret(expr, ctx),
        OperatorCategory::PatternMatch => pattern_match::interpret(expr, ctx),
        OperatorCategory::Presence => match expr {
            Expr::Presence { .. } => presence::interpret(expr, ctx),
            Expr::Assignment { .. } => presence::interpret_assignment(expr, ctx),
            _ => Err(Refusal::TypeMismatch(format!("dispatch_operator(Presence, ..) called with {expr:?} — a router bug"))),
        },
        OperatorCategory::Text => text::interpret(expr, ctx),
        OperatorCategory::Positional => positional::interpret(expr, ctx),
    }
}

/// `Resolver#fetch`: the head segment checks `args` then `instance`;
/// later segments walk `composite::step`. Only the head segment can
/// refuse here — canonical text is validated at boot, so any refusal
/// past this point is a codegen bug, not a real business refusal.
fn lookup(path: &str, ctx: &EvalContext) -> Result<Value, Refusal> {
    composite::finish(lookup_field(path, ctx)?, path)
}

/// `lookup`'s walk, stopped before the last field collapses to a scalar: a path may end on a
/// nested object, which `.set?` reads as present without needing it to be one value.
pub(crate) fn lookup_field<'a>(path: &str, ctx: &EvalContext<'a>) -> Result<Field<'a>, Refusal> {
    let mut segments = path.split('.');
    let head = segments.next().unwrap();
    let mut current = ctx
        .args
        .field(head)
        .or_else(|| ctx.instance.field(head))
        .ok_or_else(|| eval_error(format!("cannot resolve {head:?} — no such attribute or argument")))?;

    for seg in segments {
        current = composite::step(current, seg, head)?;
    }

    Ok(current)
}

/// The list-elements reading of a `Lookup` path — same head resolution
/// as `lookup`, then `Fielded::items` on the last segment (a list is
/// always the end of a path). `op` names the caller for error wording.
pub(crate) fn lookup_items<'a>(path: &str, ctx: &EvalContext<'a>, op: &str) -> Result<Vec<Field<'a>>, Refusal> {
    let segments: Vec<&str> = path.split('.').collect();
    let (head, rest) = segments.split_first().unwrap();

    if rest.is_empty() {
        // args first when the key is present there, state second — a
        // non-list argument refuses rather than falling through to a
        // same-named instance list.
        let side: &'a dyn Fielded = if ctx.args.field(head).is_some() { ctx.args } else { ctx.instance };
        return side
            .items(head)
            .ok_or_else(|| eval_error(format!("{op} expects a list, got {}", describe_field(side.field(head)))));
    }

    let (last, middle) = rest.split_last().unwrap();
    let mut current = ctx
        .args
        .field(head)
        .or_else(|| ctx.instance.field(head))
        .ok_or_else(|| eval_error(format!("cannot resolve {head:?} — no such attribute or argument")))?;
    for seg in middle {
        current = composite::step(current, seg, head)?;
    }
    match current {
        Field::Nested(obj) => obj
            .items(last)
            .ok_or_else(|| eval_error(format!("{op} expects a list, got {}", describe_field(obj.field(last))))),
        Field::Value(v) => Err(eval_error(format!("{path} — cannot look up {last:?} on scalar {v:?}"))),
    }
}

fn describe_field(field: Option<Field<'_>>) -> String {
    match field {
        None => "nothing".to_string(),
        Some(Field::Value(v)) => format!("{v:?}"),
        Some(Field::Nested(_)) => "an object".to_string(),
    }
}

pub(crate) fn eval_error(message: String) -> Refusal {
    Refusal::Fault(message)
}

#[cfg(test)]
mod lookup_tests {
    use super::*;

    // Shaped like a generated value object: one required boolean field,
    // one optional — the exact shape `!previous_sessions.nil?` names
    // (see `composite::step`'s own header).
    struct Attendee {
        previous_sessions: bool,
        first_time: Option<bool>,
    }
    impl Fielded for Attendee {
        fn field(&self, name: &str) -> Option<Field<'_>> {
            match name {
                "previous_sessions" => Some(Field::Value(Value::Bool(self.previous_sessions))),
                "first_time" => Some(match self.first_time {
                    Some(b) => Field::Value(Value::Bool(b)),
                    None => Field::Value(Value::Nil),
                }),
                _ => None,
            }
        }
    }

    fn not_nil(field: &'static str, instance: &dyn Fielded) -> Value {
        let expr = Expr::Not(Box::new(Expr::Lookup(field)));
        let ctx = EvalContext { args: &NoFields, instance };
        interpret(&expr, &ctx).expect("evaluates without refusing")
    }

    #[test]
    fn a_present_true_boolean_answers_not_nil() {
        // `!previous_sessions.nil?` — the live crash, `previous_sessions:
        // true`: `.nil?` is not a dedicated node in this grammar, so this
        // is really `Lookup("previous_sessions.nil?")` negated.
        let attendee = Attendee { previous_sessions: true, first_time: None };
        assert_eq!(not_nil("previous_sessions.nil?", &attendee), Value::Bool(true));
    }

    #[test]
    fn a_present_false_boolean_also_answers_not_nil() {
        // The other half of the live crash: `false` is exactly as
        // present as `true` — `walk_path` never inspects the value,
        // only whether the head attribute resolved at all.
        let attendee = Attendee { previous_sessions: false, first_time: None };
        assert_eq!(not_nil("previous_sessions.nil?", &attendee), Value::Bool(true));
    }

    #[test]
    fn a_genuinely_unset_optional_field_still_answers_not_nil() {
        // Matches Ruby parity: `walk_path` breaks to `nil` off any
        // scalar before inspecting `.nil?`'s segment name, so `!x.nil?`
        // reads `true` for any head attribute that resolved, set or not.
        let attendee = Attendee { previous_sessions: true, first_time: None };
        assert_eq!(not_nil("first_time.nil?", &attendee), Value::Bool(true));
    }

    #[test]
    fn a_genuinely_missing_head_attribute_still_refuses() {
        // An undeclared head attribute is still a codegen bug, not a
        // legitimate absent value — see `lookup`'s own doc comment.
        let attendee = Attendee { previous_sessions: true, first_time: None };
        let expr = Expr::Not(Box::new(Expr::Lookup("not_a_real_attribute.nil?")));
        let ctx = EvalContext { args: &NoFields, instance: &attendee };
        assert!(interpret(&expr, &ctx).is_err());
    }
}
