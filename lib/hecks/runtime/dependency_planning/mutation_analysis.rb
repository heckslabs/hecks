module Hecks
  module Runtime
    module DependencyPlanning
      class Analyzer
        # What a command's mutations read and write, and what a fresh record already holds.
        # Mixed into {Analyzer}, which owns the sets these methods fill.
        module MutationAnalysis
          STATEFUL_MUTATIONS = %i[append increment decrement multiply clamp remove].freeze

          private

          # A fresh Instance supplies these values without a stored record; keep aligned with
          # Instance.defaults/default_for. They are not command mutations, so not in write_set.
          def analyze_initial_state
            aggregate.attributes.each do |attribute|
              known_writes << attribute.name if deterministic_initial_value?(attribute)
            end

            known_writes << aggregate.lifecycle.field.to_sym if aggregate.lifecycle
          end

          def deterministic_initial_value?(attribute)
            return true if declared_without_prior_state?(attribute)
            return false unless aggregate.respond_to?(:value_object)

            value_object = aggregate.value_object(attribute.type)
            value_object&.attributes&.all? { |field| !field.default.nil? }
          end

          def declared_without_prior_state?(attribute)
            attribute.list? || attribute.optional? || !attribute.default.nil?
          end

          def analyze_mutations
            command.mutations.each { |mutation| analyze_mutation(mutation) }
          end

          def analyze_mutation(mutation)
            target = mutation.target.to_sym
            writes << target

            if owner_fields.include?(target)
              analyze_operation(mutation, target)
            else
              unresolved << "mutation target #{target} is not an aggregate field"
            end
          end

          def analyze_operation(mutation, target)
            if mutation.op == :set
              known_writes << target if analyze_source?(mutation.source)
            elsif STATEFUL_MUTATIONS.include?(mutation.op)
              state_reads << target
              analyze_source?(mutation.source)
            else
              unresolved << "mutation operation #{mutation.op} has no dependency rule"
            end
          end

          # True only when the source is known without prior state. Hash sources are append
          # bindings.
          def analyze_source?(source)
            case source
            when Symbol
              analyze_symbol_source?(source)
            when Hash
              source.values.map { |value| analyze_source?(value) }.all?
            else
              true
            end
          end

          def analyze_symbol_source?(source)
            if payload_fields.include?(source)
              payload_reads << source
              true
            elsif owner_fields.include?(source)
              state_reads << source
              false
            else
              unresolved << "mutation source #{source} has no payload or aggregate field"
              false
            end
          end
        end
      end
    end
  end
end
