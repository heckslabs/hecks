# lib/hecks_specializer/validator_warnings.rb
#
# Hecks::Specializer::ValidatorWarnings — emits validator_warnings.rs.
# Moved from bin/specialize-validator-warnings.

module Hecks
  module Specializer
    class ValidatorWarnings
      include Target

      SHAPE = REPO_ROOT.join("hecks_conception/capabilities/validator_warnings_shape/fixtures/validator_warnings_shape.fixtures")
      TARGET_RS = REPO_ROOT.join("hecks_life/src/validator_warnings.rs")

      def emit
        rules = by_aggregate("WarningRule")
        [
          emit_header,
          emit_imports,
          rules.map { |r| emit_rule(r) }.join,
        ].join
      end

      private

      def emit_header
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
      end

      def emit_imports
        <<~RS
          use crate::ir::Domain;
          use std::collections::{HashMap, HashSet, VecDeque};

        RS
      end

      def emit_rule(rule)
        case rule["attrs"]["body_strategy"]
        when "templated" then emit_templated(rule)
        when "embedded"  then emit_embedded(rule)
        else raise "unknown body_strategy: #{rule["attrs"]["body_strategy"]}"
        end
      end

      def emit_templated(rule)
        case rule["attrs"]["check_kind"]
        when "count_threshold" then emit_count_threshold(rule)
        else raise "unknown templated check_kind: #{rule["attrs"]["check_kind"]}"
        end
      end

      def emit_count_threshold(rule)
        a = rule["attrs"]
        threshold = a["threshold"].to_i
        doc = "Returns Some(msg) if the domain has more than #{threshold} aggregates."
        <<~RS
          /// #{doc}
          pub fn #{a["rust_fn_name"]}(domain: &Domain) -> Option<String> {
              if domain.aggregates.len() > #{threshold} {
                  Some(format!(
                      "#{a["message_template"]}",
                      domain.name,
                      domain.aggregates.len()
                  ))
              } else {
                  None
              }
          }

        RS
      end

      def emit_embedded(rule)
        a = rule["attrs"]
        path = REPO_ROOT.join(a["snippet_path"])
        body = read_snippet_body(path)
        threshold = a["threshold"].to_i
        doc = [
          "Returns Some(msg) if the domain has #{threshold}+ aggregates split across",
          "disconnected reference/policy clusters.",
        ]
        <<~RS
          /// #{doc[0]}
          /// #{doc[1]}
          pub fn #{a["rust_fn_name"]}(domain: &Domain) -> Option<String> {
          #{body}}
        RS
      end
    end

    register :validator_warnings, ValidatorWarnings
  end
end
