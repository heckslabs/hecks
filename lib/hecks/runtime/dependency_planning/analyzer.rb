require_relative "mutation_analysis"
require_relative "rule_analysis"

module Hecks
  module Runtime
    module DependencyPlanning
      # Static dependency analysis for one command: derives a Plan without executing it.
      # CommandInterpreter and EntityInterpreter consult it before choosing a dispatch strategy.
      class Analyzer
        include MutationAnalysis
        include RuleAnalysis

        STATEFUL_MUTATIONS = MutationAnalysis::STATEFUL_MUTATIONS

        # `root_aggregate:` is the owner a `parent.*` read resolves against. An entity-owned
        # command passes `aggregate:` as the entity, whose fields never include root-level ones.
        #
        # @param aggregate [Bluebook::Aggregate, Bluebook::Entity] the construct the command
        #   is dispatched against; an entity for an entity-owned command
        # @param command [Bluebook::Command] the command to analyze
        # @param root_aggregate [Bluebook::Aggregate] the owning aggregate a `parent.*` read
        #   resolves against; defaults to `aggregate` for a plain-aggregate command
        # @return [Hecks::Runtime::DependencyPlanning::Plan] the derived, frozen plan
        def self.call(aggregate:, command:, root_aggregate: aggregate) = new(aggregate, command, root_aggregate).call

        # @param aggregate [Bluebook::Aggregate, Bluebook::Entity] the construct the command
        #   is dispatched against
        # @param command [Bluebook::Command] the command to analyze
        # @param root_aggregate [Bluebook::Aggregate] the owning aggregate `parent.*` reads
        #   resolve against; defaults to `aggregate`
        def initialize(aggregate, command, root_aggregate = aggregate)
          @aggregate = aggregate
          @command = command
          @owner_fields = owner_field_names(aggregate)
          @root_owner_fields = owner_field_names(root_aggregate)
          @payload_fields = command.attributes.to_set(&:name)
          @state_reads, @payload_reads, @writes, @known_writes, @unresolved = Array.new(5) { Set.new }
        end

        # Runs the analysis and derives the command's dependency plan.
        #
        # @return [Hecks::Runtime::DependencyPlanning::Plan] the derived, frozen plan
        def call
          analyze_initial_state
          analyze_mutations
          analyze_lifecycle
          analyze_command_rules
          add_preservation_reads

          build_plan(unresolved.empty? && owner_fields.subset?(known_writes))
        end

        private

        attr_reader :aggregate, :command, :owner_fields, :root_owner_fields, :payload_fields,
                    :state_reads, :payload_reads, :writes, :known_writes, :unresolved

        # The fields a rule may read off `construct`: its attributes, its lifecycle field, and its
        # `projects` fields. A projected field is owner state: a rule reading one reads this
        # record's stored field. Left out of `known_writes` so `add_preservation_reads` keeps it
        # as a read; the interpreter reseeds it on save.
        def owner_field_names(construct)
          fields = construct.attributes.to_set(&:name)
          fields << construct.lifecycle.field.to_sym if construct.lifecycle
          construct.projected_fields.each { |field| fields << field.name } if construct.respond_to?(:projected_fields)
          fields
        end

        def analyze_command_rules
          analyze_rules(command.givens, phase: :before)
          analyze_rules(command.ensures, phase: :after)
          analyze_rules(aggregate.invariants, phase: :after)
        end

        def build_plan(complete)
          Plan.new(
            read_set:                sorted(state_reads),
            write_set:               sorted(writes),
            payload_read_set:        sorted(payload_reads),
            complete_state:          complete,
            state_independent:       complete && state_reads.empty?,
            unresolved_dependencies: unresolved.to_a.sort.freeze
          ).freeze
        end

        def sorted(values) = values.to_a.sort.freeze
      end
    end
  end
end
