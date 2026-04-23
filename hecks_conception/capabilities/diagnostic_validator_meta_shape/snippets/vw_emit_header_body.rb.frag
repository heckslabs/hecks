        <<~RS
          //! Soft warnings for domain quality — non-failing bounded-context checks
          //!
          //! GENERATED FILE — do not edit.
          //! Source:    hecks_conception/capabilities/validator_warnings_shape/
          //! Regenerate: bin/specialize validator_warnings --output hecks_life/src/validator_warnings.rs
          //! Contract:  specializer.hecksagon :specialize_validator_warnings shell adapter
          //! Tests:     hecks_life/tests/validator_warnings_test.rs
          //!
          //! These rules emit advisory warnings but never cause validation to fail.
          //! They help domain modelers spot bounded-context smell early.
          //!
          //! Usage:
          //!   if let Some(msg) = validator_warnings::aggregate_count_warning(&domain) {
          //!       println!("  {}", msg);
          //!   }
          //!   if let Some(msg) = validator_warnings::mixed_concerns_warning(&domain) {
          //!       println!("  {}", msg);
          //!   }

        RS
