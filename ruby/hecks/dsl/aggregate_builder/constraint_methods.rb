# Hecks::DSL::AggregateBuilder::ConstraintMethods
#
# Validation and invariant DSL methods extracted from AggregateBuilder.
#
module Hecks
  module DSL
    class AggregateBuilder
      module ConstraintMethods
        # Add a field-level validation rule.
        #
        # @param field [Symbol] the attribute name to validate
        # @param rules [Hash] validation rules (e.g. +{ presence: true }+)
        # @return [void]
        def validation(field, rules)
          @validations << BluebookModel::Structure::Validation.new(field: field, rules: rules)
        end

        # Define an aggregate-level invariant (f4).
        #
        # The f4 form declares a named rule whose `holds_when { ... }`
        # predicate the runtime evaluates on the RESULTING state after
        # EVERY command, before save :
        #
        #   invariant "ready_means_verified" do
        #     holds_when { state != "done" || verified == true }
        #   end
        #
        # The legacy direct-block form (`invariant("msg") { ... }`) still
        # works — documentation-only, no captured predicate.
        #
        # @param message [String] the rule name / human-readable description
        # @yield block declaring `holds_when { <predicate> }`, or a direct
        #   predicate (legacy)
        # @return [void]
        def invariant(message, &block)
          capture = HoldsWhenCapture.new
          # Only the f4 `holds_when { ... }` form is captured as a machine
          # predicate (holds_when reads its inner block's SOURCE, never
          # executing it). The legacy direct-block form
          # (`invariant("msg") { scope == ... }`) is documentation-only :
          # instance_eval would evaluate its bare attribute names as method
          # calls on the capture and raise NameError. We rescue that and
          # leave the expression nil — mirroring the Rust parser (which
          # records an expression ONLY for the holds_when form) and
          # ValueObjectBuilder (which never executes the block). canonical_ir
          # then filters nil-expression invariants, so both sides agree.
          begin
            capture.instance_eval(&block) if block
          rescue NameError
            # direct-form predicate over attributes — documentation-only
          end
          @invariants << BluebookModel::Structure::Invariant.new(
            message: message,
            block: capture.predicate || block,
            expression: capture.expression
          )
        end

        # Captures the `holds_when { ... }` predicate inside an `invariant`
        # block (f4), reading its source text the same way CommandBuilder
        # reads a `given` predicate — so the canonical IR carries the
        # single-line expression byte-identically with the Rust parser.
        class HoldsWhenCapture
          attr_reader :predicate, :expression

          def holds_when(&block)
            @predicate = block
            @expression = extract_predicate_source(block)
          end

          private

          def extract_predicate_source(block)
            file, line = block.source_location
            return nil unless file && File.exist?(file)
            source_line = File.readlines(file)[line - 1].to_s.strip
            source_line =~ /\{(.+)\}/ ? Regexp.last_match(1).strip : source_line
          end
        end

        # Deprecated: ports moved to Hecksagon as gates. Kept as no-op for compatibility.
        def port(_name, _methods = nil, &_block); end
      end
    end
  end
end
