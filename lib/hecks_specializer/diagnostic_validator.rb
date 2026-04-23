# lib/hecks_specializer/diagnostic_validator.rb
#
# Hecks::Specializer::DiagnosticValidator — base class for the Phase B
# diagnostic-style validator retirements (duplicate_policy, lifecycle, io).
#
# Each subclass defines:
#   SHAPE      — path to its <target>_validator_shape.fixtures
#   TARGET_RS  — path to the .rs file it emits
#
# The base class handles the emission pipeline:
#   header → imports → Report (by report_kind) → helpers → rule
#
# Shape schema (identical across subclasses):
#
#   DiagnosticValidator (1 row):
#     module, doc_snippet, imports, report_kind, rule_fn_name,
#     rule_signature, check_body_snippet
#
#   DiagnosticHelper (N rows):
#     validator, name, doc_comment, signature, body_snippet, order
#
# report_kind dispatches to canned Report templates:
#   flat                     — findings: Vec<Finding>, errors/passes
#   flat_with_strict         — + warnings, passes(strict)
#   partitioned_with_strict  — static + runtime findings, strict
#
# Empty-body helpers (like #[allow(dead_code)] stubs) emit inline:
# `fn x() {}` instead of `fn x() {\n}`.

module Hecks
  module Specializer
    class DiagnosticValidator
      include Target

      def emit
        validator = by_aggregate("DiagnosticValidator").first
        helpers = by_aggregate("DiagnosticHelper")
                    .select { |h| h["attrs"]["validator"] == validator["attrs"]["module"] }
                    .sort_by { |h| h["attrs"]["order"].to_i }
        helpers_first = validator["attrs"]["helpers_after_rule"] != "true"
        parts = [emit_header(validator), emit_imports(validator), emit_report(validator["attrs"]["report_kind"])]
        if helpers_first
          # duplicate_policy style: Report → helpers → rule (rule last, no trailing blank)
          parts << helpers.map { |h| emit_helper(h) }.join
          parts << emit_rule(validator, leading_blank: true)
        else
          # lifecycle/io style: Report → rule → helpers (last helper no trailing blank)
          parts << emit_rule(validator, leading_blank: false, trailing_blank: true)
          helpers.each_with_index do |h, i|
            parts << emit_helper(h, trailing_blank: i < helpers.size - 1)
          end
        end
        parts.join
      end

      private

      def emit_header(validator)
        path = REPO_ROOT.join(validator["attrs"]["doc_snippet"])
        File.read(path) + "\n"
      end

      def emit_imports(validator)
        extras = validator["attrs"]["imports"].split("\n").reject(&:empty?)
        lines = ["pub use crate::diagnostic::{Finding, Severity};"]
        extras.each { |imp| lines << "use #{imp};" }
        lines.join("\n") + "\n\n"
      end

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
        <<~RS
          pub struct Report {
              pub findings: Vec<Finding>,
          }

          impl Report {
              pub fn errors(&self) -> usize {
                  self.findings.iter().filter(|f| f.severity == Severity::Error).count()
              }
              pub fn warnings(&self) -> usize {
                  self.findings.iter().filter(|f| f.severity == Severity::Warning).count()
              }
              pub fn passes(&self, strict: bool) -> bool {
                  if self.errors() > 0 { return false; }
                  if strict && self.warnings() > 0 { return false; }
                  true
              }
          }

        RS
      end

      def emit_report_partitioned_with_strict
        raise "emit_report_partitioned_with_strict not wired yet — arrives with io retirement"
      end

      def emit_helper(helper, trailing_blank: false)
        a = helper["attrs"]
        body = File.read(REPO_ROOT.join(a["body_snippet"]))
        doc = a["doc_comment"].to_s
        # doc_comment is the PREAMBLE — may hold /// doc, // comments,
        # and/or #[attribute] lines. Emit verbatim if present.
        doc_block = doc.empty? ? "" : doc + "\n"
        core = if body.strip.empty?
                 # Empty-body stubs (e.g. #[allow(dead_code)] placeholders)
                 # emit inline: `fn x() {}` on one line.
                 "#{doc_block}#{a["signature"]} {}\n"
               else
                 "#{doc_block}#{a["signature"]} {\n#{body}}\n"
               end
        trailing_blank ? core + "\n" : core
      end

      def emit_rule(validator, leading_blank: true, trailing_blank: false)
        a = validator["attrs"]
        body = File.read(REPO_ROOT.join(a["check_body_snippet"]))
        prefix = leading_blank ? "\n" : ""
        suffix = trailing_blank ? "\n" : ""
        "#{prefix}#{a["rule_signature"]} {\n#{body}}\n#{suffix}"
      end
    end
  end
end
