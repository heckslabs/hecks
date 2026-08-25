//! Port of `rust/project/expr_emitter.rb` — walks the AST `expr::parse`
//! (this crate's own port of `Evaluator.parse`/`Resolver.parse`) produces
//! and emits Rust `Expr` data-literal source, mirroring the Ruby file's
//! `emit_bool`/`emit_resolver`/`emit_comparison` directly, node for node.

use crate::expr::evaluator::Evaluator;
use crate::expr::resolver::Resolver;
use crate::expr::Operator;
use crate::naming::ruby_inspect_string;

pub fn emit_predicate(canonical: &str) -> String {
    emit_bool(&crate::expr::evaluator::parse(canonical))
}

pub fn emit_bool(node: &Evaluator) -> String {
    match node {
        Evaluator::Or(left, right) => format!("Expr::Or(Box::new({}), Box::new({}))", emit_bool(left), emit_bool(right)),
        Evaluator::And(left, right) => format!("Expr::And(Box::new({}), Box::new({}))", emit_bool(left), emit_bool(right)),
        Evaluator::Not(inner) => format!("Expr::Not(Box::new({}))", emit_bool(inner)),
        Evaluator::Compare { operator, left, right } => {
            format!("Expr::Compare {{ op: {}, left: Box::new({}), right: Box::new({}) }}", emit_comparison(operator), emit_resolver(left), emit_resolver(right))
        }
        Evaluator::Include { haystack, needle } => emit_include(haystack, needle),
        Evaluator::Resolve(expr) => emit_resolver(expr),
    }
}

pub fn emit_comparison(op: &Operator) -> String {
    format!("crate::kernel::Comparison {{ less_than: {}, equal: {}, negated: {} }}", op.compares_less_than, op.compares_equal, op.negated)
}

/// Port of `rust/project/expr_emitter.rb`'s own `emit_include` — see that
/// file's own header comment for the full reasoning. Short version: the
/// kernel's `Value::List` is a length, never a real element set, so a
/// LITERAL haystack (`["issued", "active"].include?(status)`) is
/// rewritten into `needle == "issued" || needle == "active"` at
/// generation time, using the SAME `Expr::Compare`/`Expr::Or` every other
/// equality/either-or check already compiles to — not a new kernel
/// `Value` shape for a haystack that's always fully known before a
/// single record is ever read. A non-literal haystack (a real list-typed
/// field, or a String) still emits `Expr::Include` unchanged.
fn emit_include(haystack: &Resolver, needle: &Resolver) -> String {
    let Resolver::ArrayLiteral(elements) = haystack else {
        return format!("Expr::Include {{ haystack: Box::new({}), needle: Box::new({}) }}", emit_resolver(haystack), emit_resolver(needle));
    };

    if elements.is_empty() {
        return "Expr::Bool(false)".to_string();
    }

    let eq = crate::expr::find_operator("==");
    elements
        .iter()
        .map(|element| format!("Expr::Compare {{ op: {}, left: Box::new({}), right: Box::new({}) }}", emit_comparison(&eq), emit_resolver(needle), emit_resolver(element)))
        .reduce(|left, right| format!("Expr::Or(Box::new({left}), Box::new({right}))"))
        .unwrap()
}

pub fn emit_resolver(node: &Resolver) -> String {
    match node {
        Resolver::IntegerLiteral(v) => format!("Expr::Int({v})"),
        Resolver::FloatLiteral(v) => format!("Expr::Float({v}f64)"),
        Resolver::StringLiteral(v) => format!("Expr::Str({}.to_string())", ruby_inspect_string(v)),
        Resolver::BoolLiteral(v) => format!("Expr::Bool({v})"),
        Resolver::NilLiteral => "Expr::Nil".to_string(),
        Resolver::Lookup(path) => format!("Expr::Lookup({})", ruby_inspect_string(path)),
        Resolver::Addition(left, right) => format!("Expr::Add(Box::new({}), Box::new({}))", emit_resolver(left), emit_resolver(right)),
        Resolver::SignTest { operator, receiver } => format!("Expr::SignTest {{ op: {}, receiver: Box::new({}) }}", emit_comparison(operator), emit_resolver(receiver)),
        Resolver::Empty(receiver) => format!("Expr::Empty(Box::new({}))", emit_resolver(receiver)),
        Resolver::ToS(receiver) => format!("Expr::ToS(Box::new({}))", emit_resolver(receiver)),
        Resolver::Modulo { receiver, divisor } => format!("Expr::Modulo {{ receiver: Box::new({}), divisor: Box::new({}) }}", emit_resolver(receiver), emit_resolver(divisor)),
        Resolver::Size(receiver) => format!("Expr::Size(Box::new({}))", emit_resolver(receiver)),
        Resolver::BlockPredicate { mode, receiver, param, predicate } => format!(
            "Expr::BlockPredicate {{ mode: crate::kernel::BlockMode::{}, receiver: Box::new({}), param: {}, predicate: Box::new({}) }}",
            mode.rust_name(),
            emit_resolver(receiver),
            ruby_inspect_string(param),
            emit_bool(predicate)
        ),
        Resolver::Find { receiver, param, predicate, path } => format!(
            "Expr::Find {{ receiver: Box::new({}), param: {}, predicate: Box::new({}), path: &[{}] }}",
            emit_resolver(receiver),
            ruby_inspect_string(param),
            emit_bool(predicate),
            path.iter().map(|segment| ruby_inspect_string(segment)).collect::<Vec<_>>().join(", ")
        ),
        // Never reached in practice — `emit_include`, above, intercepts
        // an `ArrayLiteral` haystack before it would ever recurse in
        // here (the only shape the real grammar ever builds one for; see
        // `Vocabulary::IncludeHaystack`). Kept as a real panic rather
        // than folded into a `_ =>` arm, matching this match's own "no
        // silent Unsupported case" discipline — a bare array literal
        // reaching here is a genuinely new shape this generator has no
        // rendering for yet, not a case to paper over.
        Resolver::ArrayLiteral(_) => panic!("unhandled resolver node ArrayLiteral outside an Include haystack — the real grammar never builds one there; this generator is stale"),
    }
}
