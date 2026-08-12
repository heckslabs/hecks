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
        Evaluator::Include { haystack, needle } => format!("Expr::Include {{ haystack: Box::new({}), needle: Box::new({}) }}", emit_resolver(haystack), emit_resolver(needle)),
        Evaluator::Resolve(expr) => emit_resolver(expr),
    }
}

pub fn emit_comparison(op: &Operator) -> String {
    format!("crate::kernel::Comparison {{ less_than: {}, equal: {}, negated: {} }}", op.compares_less_than, op.compares_equal, op.negated)
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
    }
}
