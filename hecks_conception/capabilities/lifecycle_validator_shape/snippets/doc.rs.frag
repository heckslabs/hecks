//! Lifecycle validator
//!
//! GENERATED FILE — do not edit.
//! Source:    hecks_conception/capabilities/lifecycle_validator_shape/
//! Regenerate: hecks-life specialize lifecycle --output hecks_life/src/lifecycle_validator.rs
//! Contract:  hecks_life/src/specializer/lifecycle_validator.rs (Rust-native)
//! Tests:     hecks_life/tests/lifecycle_validator_test.rs
//!
//! Catches contradictions in lifecycle declarations — patterns where
//! a transition is structurally unreachable from any state the
//! aggregate can actually be in.
//!
//! The most common bug this catches:
//!
//!   attribute :status, default: "active"
//!   lifecycle :status do
//!     transition "OpenRecord" => "active", from: "none"
//!   end
//!
//! New aggregates start with `status = "active"` (the default).
//! `OpenRecord` requires `from: "none"`. Nothing transitions to "none".
//! Therefore OpenRecord can never fire. The bluebook is contradictory.
//!
//! Two checks:
//!
//! 1. **Unreachable from_state.** A transition's `from:` value must be
//!    either the lifecycle default OR the to_state of some other
//!    transition. Otherwise the transition is dead.
//!
//! 2. **Stuck default.** If the lifecycle has transitions but none of
//!    them can fire from the default state, the aggregate is stuck
//!    in default forever. Warning.
//!
//! Surface:
//!
//!   hecks-life check-lifecycle path/to/bluebook.bluebook
//!   hecks-life check-lifecycle path/to/bluebook.bluebook --strict
//!
//! Exit code:
//!   0 — no errors (and no warnings if --strict isn't set)
//!   1 — at least one error, or --strict and at least one warning
