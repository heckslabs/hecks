pub mod evaluator;
pub mod resolver;

// Its own fixtures parse fresh bluebook text via `bluebook::parser`.
#[cfg(all(test, feature = "parser"))]
mod tests;
