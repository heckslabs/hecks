require_relative "expression_reads"

module Hecks
  module Runtime
    module DependencyPlanning
      class Analyzer
        # What a command's lifecycle, givens, ensures and invariants read. Mixed into
        # {Analyzer}, which owns the sets these methods fill.
        module RuleAnalysis
          private

          def analyze_lifecycle
            lifecycle = aggregate.lifecycle
            return unless lifecycle

            state_reads << lifecycle.field if command.from
            record_lifecycle_write(lifecycle) unless lifecycle.transitions_for(command.hecks_name).empty?
          end

          def record_lifecycle_write(lifecycle)
            writes << lifecycle.field
            known_writes << lifecycle.field
          end

          def analyze_rules(rules, phase:)
            rules.each do |rule|
              ExpressionReads.paths(rule.canonical).each { |path| classify_path(path, phase) }
            rescue ArgumentError => e
              unresolved << "expression #{rule.canonical.inspect} could not be analyzed: #{e.message}"
            end
          end

          # Gap: the `as:` name bound by `corrects` is not special-cased like `:old`/`:parent`, so a
          # rule reading it lands in `unresolved` and dispatch takes the safe `hydrate_existing`
          # path. Runtime binding is unaffected.
          def classify_path(path, phase)
            head, nested = path.split(".", 2)
            name = head.to_sym

            case name
            when :parent
              # `parent.X` names the root aggregate's field, not the entity's `owner_fields`;
              # the two sets are identical for a plain aggregate command.
              resolve_nested_state_read!(path, nested, root_owner_fields, "does not name parent aggregate state")
            when :old
              resolve_nested_state_read!(path, nested, owner_fields, "does not name prior aggregate state")
            else
              classify_named_path(path, name, phase)
            end
          end

          def classify_named_path(path, name, phase)
            if payload_fields.include?(name)
              payload_reads << name
            elsif owner_fields.include?(name)
              state_reads << name if phase == :before || !known_writes.include?(name)
            else
              unresolved << "expression path #{path} has no payload or aggregate field"
            end
          end

          # Shared by the `:parent`/`:old` branches: checks the nested field against `field_set`
          # and records a state read, or refuses with `message`.
          def resolve_nested_state_read!(path, nested, field_set, message)
            field = nested.to_s.split(".", 2).first
            if field.empty? || !field_set.include?(field.to_sym)
              unresolved << "#{path} #{message}"
            else
              state_reads << field.to_sym
            end
          end

          # A partial mutation must preserve every untouched field, so those prior values are
          # reads even when no rule names them.
          def add_preservation_reads
            state_reads.merge(owner_fields - known_writes)
          end
        end
      end
    end
  end
end
