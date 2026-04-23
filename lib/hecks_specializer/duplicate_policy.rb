# lib/hecks_specializer/duplicate_policy.rb
#
# Hecks::Specializer::DuplicatePolicy — emits
# hecks_life/src/duplicate_policy_validator.rs.
#
# First retirement under the shared DiagnosticValidator shape (post-i59).
# Exercises: flat report_kind, single DiagnosticHelper, embedded check body.
# Sets the pattern for the next two retirements (lifecycle, io).

module Hecks
  module Specializer
    class DuplicatePolicy
      include Target

      SHAPE = REPO_ROOT.join("hecks_conception/capabilities/duplicate_policy_validator_shape/fixtures/duplicate_policy_validator_shape.fixtures")
      TARGET_RS = REPO_ROOT.join("hecks_life/src/duplicate_policy_validator.rs")

      def emit
        validator = by_aggregate("DiagnosticValidator").first
        helpers = by_aggregate("DiagnosticHelper")
                    .select { |h| h["attrs"]["validator"] == validator["attrs"]["module"] }
                    .sort_by { |h| h["attrs"]["order"].to_i }
        [
          emit_header(validator),
          emit_imports(validator),
          emit_report(validator["attrs"]["report_kind"]),
          helpers.map { |h| emit_helper(h) }.join,
          emit_rule(validator),
        ].join
      end

      private

      def emit_header(validator)
        # Raw read — the doc_snippet file already has //! prefixes and
        # exact line breaks that go into the .rs verbatim.
        path = REPO_ROOT.join(validator["attrs"]["doc_snippet"])
        File.read(path) + "\n"
      end

      def emit_imports(validator)
        # Always: pub use of the shared diagnostic types (i59 contract).
        # Then per-validator extra imports, split by \n in the fixture.
        extras = validator["attrs"]["imports"].split("\n").reject(&:empty?)
        lines = ["pub use crate::diagnostic::{Finding, Severity};"]
        extras.each { |imp| lines << "use #{imp};" }
        lines.join("\n") + "\n\n"
      end

      # Canned Report-struct templates. report_kind:
      #   flat                     — duplicate_policy_validator today
      #   flat_with_strict         — lifecycle_validator (next PR)
      #   partitioned_with_strict  — io_validator (PR after that)
      def emit_report(kind)
        case kind
        when "flat"                    then emit_report_flat
        when "flat_with_strict"        then emit_report_flat_with_strict
        when "partitioned_with_strict" then emit_report_partitioned_with_strict
        else raise "unknown report_kind: #{kind}"
        end
      end

      def emit_report_flat
        <<~RS
          pub struct Report {
              pub findings: Vec<Finding>,
          }

          impl Report {
              pub fn errors(&self) -> usize {
                  self.findings.iter().filter(|f| f.severity == Severity::Error).count()
              }
              pub fn passes(&self) -> bool { self.errors() == 0 }
          }

        RS
      end

      def emit_report_flat_with_strict
        raise "emit_report_flat_with_strict not wired yet — arrives with lifecycle retirement"
      end

      def emit_report_partitioned_with_strict
        raise "emit_report_partitioned_with_strict not wired yet — arrives with io retirement"
      end

      def emit_helper(helper)
        a = helper["attrs"]
        body_path = REPO_ROOT.join(a["body_snippet"])
        body = File.read(body_path)
        doc = a["doc_comment"].to_s
        # doc_comment is stored with literal "\n" separators — already
        # prefixed with /// on each line. Just emit verbatim if present.
        doc_block = doc.empty? ? "" : doc + "\n"
        "#{doc_block}#{a["signature"]} {\n#{body}}\n"
      end

      def emit_rule(validator)
        a = validator["attrs"]
        body_path = REPO_ROOT.join(a["check_body_snippet"])
        body = File.read(body_path)
        "\n#{a["rule_signature"]} {\n#{body}}\n"
      end
    end

    register :duplicate_policy, DuplicatePolicy
  end
end
