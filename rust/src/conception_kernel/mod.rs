//! conception_kernel — the kernel interpreter for the behaviors conception.
//!
//! Reads a declarative grammar (the precondition taxonomy as DATA) and EXECUTES
//! its recursion, rather than hand-authoring the transformation in imperative
//! Rust. This is the arc that makes `behaviors_conception.bluebook` the intent
//! and `behaviors_conceiver/generator.rs` a projection of it.
//!
//! The conception names one fault line:
//!   * `grammar` — the DATA layer. Each precondition KIND is a row composing
//!     GENERAL primitives (producer-seek, default-rule, satisfy). Declarable
//!     today; a new list-ish kind is a new row, no engine change.
//!   * `planner` — the ALGORITHM layer. A generic, depth-capped recursion that
//!     reads the kind's primitives and executes them, threading a
//!     `ProducedState` through the recursion. A section-concatenating
//!     specializer cannot run a recursion; only this interpreter can.
//!
//! First slice (2026-06-13): `Equals` + the list kinds (NonEmptyList,
//! MinSizeList, EmptyList) — the kinds whose `satisfy` predicate is genuinely a
//! data row. The integer kinds (GreaterThan/GreaterOrEqual/LessThan) are the
//! explicitly-harder next slice: their satisfy is a compound disjunction, not a
//! row, and that is where primitive granularity gets decided. Lifecycle/cascade
//! (transition producers, the Unsatisfiable→skip outcome) is a third slice.
//!
//! This module runs PARALLEL to `behaviors_conceiver/generator.rs`. generator.rs
//! is replaced only at the final gate (all 19 inline fixtures green + fresh
//! corpus byte-identical + smoke). Until then the kernel is gated on the subset
//! of the inline fixtures whose kinds it covers.
//!
//! Usage:
//!   let plan = conception_kernel::planner::plan(agg, cmd);
//!   // Plan::Chain(["AddItem", "AddItem", "AddItem"]) for `items.size >= 3`.

pub mod grammar;
pub mod sample;
pub mod recognize;
pub mod produced_state;
pub mod producers;
pub mod planner;
