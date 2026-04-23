//! Duplicate policy validator
//!
//! GENERATED FILE — do not edit.
//! Source:    hecks_conception/capabilities/duplicate_policy_validator_shape/
//! Regenerate: bin/specialize duplicate_policy --output hecks_life/src/duplicate_policy_validator.rs
//! Contract:  specializer.hecksagon :specialize_duplicate_policy shell adapter
//! Tests:     hecks_life/tests/duplicate_policy_validator_test.rs
//!
//! Catches bluebooks that declare two or more policies wired to the
//! same `(on_event, trigger_command)` pair. Today this silently
//! coexists — the runtime fires every matching policy in declaration
//! order, so the trigger command runs twice per event. That's a
//! cascade bug with no error message.
//!
//! Example of the bug:
//!
//!   policy "BeatTicks"     do; on "HeartBeat"; trigger "Tick";        end
//!   policy "BeatTicksAgain" do; on "HeartBeat"; trigger "Tick";        end
//!
//! Both policies fire on HeartBeat. Both call Tick. The second is
//! almost certainly a leftover from editing/renaming; even if it's
//! intentional, one policy with a clearer name does the job.
//!
//! Surface:
//!
//!   hecks-life check-duplicate-policies path/to/bluebook.bluebook
//!
//! Exit code:
//!   0 — no duplicate (event, trigger) pairs
//!   1 — at least one pair shared by >1 policy
//!
//! This validator is a flat walk over `domain.policies` — no runtime
//! boot, no cascade traversal. Group by key, report groups of size >1.
