//! The expression evaluator shared by the kernel and the host: a structural port of Ruby's
//! `Evaluator`/`Resolver`.

/// How a path is walked and a value is read, per attribute shape.
pub mod attribute_shapes;
/// The AST, the values it evaluates to, and the interpreter.
pub mod expr;
/// One file per operator category the grammar admits.
pub mod expression_operators;
/// The refusal an expression or a dispatch ends in.
pub mod refusal;
/// How an error message names a value, as Ruby does.
pub mod rendering;
/// `Float#to_s`, as Ruby prints it.
pub mod ruby_float;

pub use refusal::Refusal;
