// HAND-WRITTEN, ONCE, GENERIC — a direct structural port of
// `Hecks::Bluebook::Expression::Evaluator` and `::Resolver`
// (docs/implemented/guides/running-a-runtime.md's "The expression grammar"), not a
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
//
// THIS FILE IS A ROUTER, NOT WHERE THE LOGIC LIVES. Every real
// interpretation rule — what `+` does, what `.empty?` does on a list vs
// a string, what a `:composite` field's dotted lookup does — is in
// `expression_operators/<category>.rs` or `attribute_shapes/<shape>.rs`,
// one file per capability, named after the exact vocabulary
// `bin/ir --meta` (attribute shapes) and `lib/hecks/bluebook/
// expression/projection.json` (operator categories) already use for it.
// `interpret`'s own match handles ONLY the leaves no capability file
// owns (literals, `Lookup`) plus `dispatch_operator`, below, which is
// EXHAUSTIVE OVER THE GENERATED `OperatorCategory` ENUM WITH NO
// WILDCARD ARM ON PURPOSE: `bin/project_kernel_capabilities` regenerates
// that enum straight from the live Ruby grammar (`OperatorCategory`'s
// own header names the exact call), so the day a `given`/`ensures`/
// invariant clause gains a new kind of operator, this match stops
// compiling until a real arm — and the file it calls into — exists for
// it. A `_ =>` arm here would silently swallow that day instead,
// routing the new category into whatever arm happened to sit above it,
// compiling cleanly while quietly interpreting the new capability WRONG.
// That failure mode is the entire reason this refactor exists, so this
// match must never grow one back.

use super::Refusal;
use crate::kernel::attribute_shapes::composite;
use crate::kernel::expression_operators::{self, comparison, OperatorCategory};

// ── VALUE — the dynamic runtime value an expression evaluates to.
// Mirrors what Ruby's `Resolver#interpret` can return (Integer/Float/
// String/true/false/nil), plus one addition: `List(usize)`. Real corpus
// expressions only ever ask `.size`/`.empty?` of a list-typed field,
// never index into its elements by expression — so a list field
// surfaces as its length, not its contents. Each variant IS one of the
// four `AttributeShape`s once resolved to a runtime value: `Int`/
// `Float`/`Str`/`Bool` are `:scalar`, `List` is `:list`, `Nil` is
// `:optional` (see `attribute_shapes/*.rs` for the shape-owned behavior
// of each).
#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    Int(i64),
    Float(f64),
    Str(String),
    Bool(bool),
    List(usize),
    Nil,
    /// A real, fully-materialised list of `Value`s — distinct from
    /// `List(usize)` (a length-only reading of a FIELD; see this enum's
    /// own header) — produced by an `ArrayLiteral` (`Resolver::
    /// ArrayLiteral`, `[a, b]`, `Expr::Array` below) or a `.split` call.
    /// `expression_operators::text::split` produces it;
    /// `expression_operators::positional` (`.first`/`.last`) is its main
    /// consumer. NOT how a literal-array `.include?` haystack reaches
    /// the kernel — `rust/project/expr_emitter.rb`'s own `emit_include`
    /// rewrites that specific shape into an OR-of-equalities at codegen
    /// time instead (see its header for why), so this variant never
    /// needs to carry `.include?`'s own membership test.
    Array(Vec<Value>),
}

impl Value {
    /// Ruby's `Evaluator.truthy?`: `!value.nil? && value != false`. Kept
    /// here, not split per-shape — every `Value` variant answers this the
    /// same generic way regardless of WHICH shape produced it, unlike
    /// `numeric`/`to_s`/`size`/`empty?`, which genuinely differ shape by
    /// shape and live in `attribute_shapes/*.rs` instead.
    pub fn truthy(&self) -> bool {
        !matches!(self, Value::Nil | Value::Bool(false))
    }
}

// ── FIELD / FIELDED — the lookup surface every generated struct (value
// object or aggregate record, and command args structs) implements. A
// dotted `Lookup` path walks this: the first segment resolves against
// args-then-instance (see `lookup`, below); every later segment walks a
// `Field::Nested` chain via `attribute_shapes::composite`. Implementations
// are mechanical and generated — one match arm per real attribute, the
// same shape for every type — not bespoke per command.
pub enum Field<'a> {
    Value(Value),
    Nested(&'a dyn Fielded),
}

pub trait Fielded {
    fn field(&self, name: &str) -> Option<Field<'_>>;

    /// A BARE (undotted) `Lookup` terminating on THIS object rather than
    /// one of its own fields — `Resolver#unwrap_scalar`'s own "not a
    /// single-field VO" fallthrough (resolver.rb, read directly): Ruby
    /// returns the whole thing as-is (a Hash), still comparable/testable
    /// generically (`==`/`!=`/`.empty?`) even though it's not a single
    /// scalar. Most `Fielded` implementers have no sensible scalar
    /// reading of themselves and don't override this (`None`, the
    /// existing "refuse — nothing generated does this" behavior,
    /// unchanged) — `reference_lookup.rs`'s `DerefNode` is the one real
    /// override: a dereferenced record collapses to the id it was
    /// fetched by, which is exactly what makes a bare `source !=
    /// destination` (`examples/banking/bluebook/`'s own
    /// `Transfer.Request`, "a transfer moves BETWEEN accounts") a real
    /// identity comparison instead of an unrepresentable object-to-object
    /// one — two references are the same reference iff they resolved to
    /// the same id, the identical fact `Value::Str` equality already
    /// tests for every OTHER string field in this grammar.
    fn as_scalar(&self) -> Option<Value> {
        None
    }

    /// THE ELEMENTS of a list-typed field, for the enumeration operators
    /// (`expression_operators/enumeration.rs` — `.any?`/`.none?`/`.all?`/
    /// `.find { |x| ... }`). `field` answers a list as `Value::List(len)`
    /// — the length, which is all `.size`/`.empty?` ever asked (see
    /// `Value`'s own header) — and stays that way; this is the SECOND
    /// reading of the same field, its members one by one, each a
    /// `Field` exactly as a nested lookup would see it (`Nested` for a
    /// value object or entity element, `Value` for a scalar list). The
    /// default answers `None` for every name, the same "refuse — nothing
    /// generated does this" reading `as_scalar` takes; `fielded.rb`/
    /// `rust/codegen/src/fielded.rs` generate an override with one arm
    /// per real list attribute (exemplar `fielded_items_arm_*`).
    fn items(&self, _name: &str) -> Option<Vec<Field<'_>>> {
        None
    }
}

/// `attrs.merge(node.param.to_sym => element)` — `Resolver::
/// interpret_with_element` (resolver/block_predicates.rb), read
/// directly: a block's own parameter is bound by MERGING it into the
/// args side for the predicate's evaluation, so it is checked before
/// every real argument and every instance field, and an argument that
/// happens to share the parameter's name is shadowed the identical way
/// in both runtimes. `rest` is whatever `args` was outside the block —
/// nested blocks chain a `Bound` inside a `Bound`, exactly as Ruby's
/// nested `merge` does.
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

    fn items(&self, name: &str) -> Option<Vec<Field<'_>>> {
        if name == "old" {
            return None;
        }
        self.args.items(name)
    }
}

/// `attrs.merge(parent: parent.state …)` — `Admissibility#enforce_givens`
/// and `#enforce_ensures`, read directly: an ENTITY command's own
/// predicates read the owning record under one name, `parent`, on the
/// args side. Built by `dispatch::apply_entity_command` for a
/// delegating door (see its own header for why the routing layer's
/// `parent_deref` snapshot is not enough there); merged AFTER `old`
/// exactly as Ruby's own `merge` order gives `old` precedence.
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

// `Comparison` used to be defined here; it now lives in
// `expression_operators::comparison` (the "comparison" category owns the
// algebra it's named for) and is re-exported at this same path so every
// call site — hand-written or generated (`rust/project/expr_emitter.rb`
// emits `crate::kernel::Comparison { .. }` literals directly) — keeps
// working unchanged.
pub use comparison::Comparison;

/// `BLOCK_PREDICATE_MODES` (resolver/block_predicates.rb): the three
/// spellings of one Array-aggregation family, kept as one node with a
/// mode exactly as Ruby keeps them (`BlockPredicate#mode`).
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

// ── EXPR — the full Evaluator + Resolver AST as one recursive Rust enum.
// Every variant corresponds to exactly one real Ruby node type:
// Evaluator::{Or,And,Not,Compare,Include,Resolve} and Resolver::
// {IntegerLiteral,FloatLiteral,StringLiteral,BoolLiteral,NilLiteral,
// Addition,SignTest,Empty,ToS,Modulo,Size,Lookup,BlockPredicate,Find}.
// `Resolve` itself
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
    /// `receiver.any? { |param| predicate }` and its `.none?`/`.all?`
    /// siblings — `Resolver::BlockPredicate`. `predicate` is a whole
    /// Evaluator-level expression (`Evaluator.parse` of the block body),
    /// evaluated once per element with `param` bound (see `Bound`).
    BlockPredicate { mode: BlockMode, receiver: Box<Expr>, param: &'static str, predicate: Box<Expr> },
    /// `receiver.find { |param| predicate }.a.b` — `Resolver::Find`: the
    /// first element the predicate accepts, projected through `path`
    /// (empty for a bare `.find { }`), or nil when nothing matches.
    Find { receiver: Box<Expr>, param: &'static str, predicate: Box<Expr>, path: &'static [&'static str] },
    /// `[a, b, c]` — `Resolver::ArrayLiteral`. A LEAF, like `Int`/`Str`/
    /// `Nil` above, not an expression-ledger OPERATOR — see expression.
    /// bluebook's own "WHAT IS NOT HERE" comment on the `Operator`
    /// aggregate: a literal's spelling doesn't differ per target the
    /// way an operation's might, so `interpret`'s leaf match handles
    /// this directly rather than routing it through `category_of`/
    /// `dispatch_operator`, the identical treatment every other literal
    /// already gets.
    Array(Vec<Expr>),
    /// `receiver.match?(/pattern/flags)` — `Resolver::MatchesRegex`. The
    /// pattern text is a real Ruby-Regexp source, taken as-is between
    /// the slashes (see `expression_operators::pattern_match`'s own
    /// header for why this crate takes a `regex` dependency for it).
    MatchesRegex { receiver: Box<Expr>, pattern: String, flags: String },
    /// `receiver.present?` / `receiver.blank?` — `Resolver::Presence`,
    /// one node for the symbol pair, `negated` distinguishing them
    /// (`.blank?` is `.present?` negated) exactly the way `SignTest`
    /// above is one node for three symbols.
    Presence { receiver: Box<Expr>, negated: bool },
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

/// `state`/`attrs` from `Evaluator.call(expr, state, attrs)` — `args` is
/// checked first for every `Lookup`, `instance` second, matching
/// `Resolver#fetch` exactly. Pass `&NoFields` for whichever side Ruby's
/// own call site would have passed `{}` for.
pub struct EvalContext<'a> {
    pub args: &'a dyn Fielded,
    pub instance: &'a dyn Fielded,
}

/// THE ROUTER. Leaves (literals, `Lookup`) are handled directly — they
/// aren't expression OPERATORS at all (`projection.json`'s own operator
/// list contains no literal/lookup entries), so they have no
/// `OperatorCategory` to route through. Everything else falls to
/// `dispatch_operator`, below.
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
/// plain, hand-written association (this enum's variant NAMES are
/// generated; which `Expr` node maps to which of them is not, since
/// `Expr` itself is hand-written and grows only when this file is
/// edited). The trailing leaf arm can't actually be reached — `interpret`
/// above never calls this for a leaf — so it says so rather than
/// silently returning a wrong category.
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
        Presence { .. } => OperatorCategory::Presence,
        Split { .. } | StartsWith { .. } | EndsWith { .. } => OperatorCategory::Text,
        First(..) | Last(..) => OperatorCategory::Positional,
        Int(..) | Float(..) | Str(..) | Bool(..) | Nil | Lookup(..) | Array(..) => {
            unreachable!("interpret's own leaf arms handle these before category_of is ever called")
        }
    }
}

/// THE CENTRAL DISPATCH POINT — see this file's own header. Exhaustive
/// over `OperatorCategory` with NO wildcard `_ =>` arm: regenerate
/// `expression_operators::OperatorCategory`
/// (bin/project_kernel_capabilities) with a variant added or removed and
/// this match stops compiling until a matching arm — and the
/// `expression_operators::<name>` file it calls into — is added or
/// removed by hand. This match must never grow a `_ =>` arm back.
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
        OperatorCategory::Presence => presence::interpret(expr, ctx),
        OperatorCategory::Text => text::interpret(expr, ctx),
        OperatorCategory::Positional => positional::interpret(expr, ctx),
    }
}

/// `Resolver#fetch`: the first path segment is checked against `attrs`
/// (args) first, `state` (instance) second; every later segment walks a
/// `Field::Nested` chain via `attribute_shapes::composite::step`. An
/// `EvaluationError` in Ruby is not one of the nine real
/// `DOMAIN_REFUSALS` — by construction, canonical text was already
/// validated when the domain booted, so reaching this in the generated
/// Rust means a codegen bug, not a real business refusal.
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
        current = composite::step(current, seg, head, path)?;
    }

    composite::finish(current, path)
}

/// The list-elements reading of a `Lookup` path, for the enumeration
/// operators: the same args-then-instance head resolution and
/// `composite::step` walk `lookup` does for every segment but the last,
/// then `Fielded::items` for the last one — a list is the end of a
/// path, never the middle of it. `op` is only for the wording
/// (`Resolver#evaluate_block_predicate`: "any? expects a list, got …").
pub(crate) fn lookup_items<'a>(path: &str, ctx: &EvalContext<'a>, op: &str) -> Result<Vec<Field<'a>>, Refusal> {
    let segments: Vec<&str> = path.split('.').collect();
    let (head, rest) = segments.split_first().unwrap();

    if rest.is_empty() {
        // `Resolver#fetch`: attrs first when the key exists there, state
        // second — decided by the FIELD's presence, so an argument that
        // is not a list refuses rather than silently falling through to
        // a same-named instance list.
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
        current = composite::step(current, seg, head, path)?;
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
    Refusal::TypeMismatch(message)
}
