require_relative "../bluebook/expression"

module Hecks
  module Runtime
    # Persistence-neutral facts derived from a command's existing semantic IR.
    # This module deliberately does not execute a plan or choose a repository.
    module DependencyPlanning
      ATOMIC_PUT = :atomic_put
      TRANSACTIONAL_FALLBACK = :load_apply_validate_store

      Plan = Struct.new(
        :read_set,
        :write_set,
        :payload_read_set,
        :complete_state,
        :state_independent,
        :unresolved_dependencies,
        keyword_init: true
      ) do
        def complete_state? = complete_state
        def state_independent? = state_independent

        # Capability negotiation is correctness-first: an optimization is
        # selected only when both the semantic proof and adapter capability
        # are present. This is planning data only; no runtime path calls it yet.
        def strategy_for(capabilities: [])
          return TRANSACTIONAL_FALLBACK unless complete_state? && state_independent?
          return TRANSACTIONAL_FALLBACK unless capabilities.map(&:to_sym).include?(ATOMIC_PUT)

          ATOMIC_PUT
        end
      end

      module ExpressionReads
        module_function

        # Read the same parsed canonical-expression nodes the evaluator uses.
        # A generic Struct walk keeps this additive when the expression grammar
        # gains a composed node; only Lookup nodes carry domain dependencies.
        def paths(canonical)
          collect(Bluebook::Expression::Evaluator.parse(canonical), Set.new)
        end

        def collect(node, bound_names)
          case node
          when Bluebook::Expression::Resolver::Lookup
            root = node.path.to_s.split(".", 2).first
            bound_names.include?(root) ? [] : [node.path.to_s]
          when Bluebook::Expression::Resolver::BlockPredicate
            collect(node.receiver, bound_names) +
              collect(node.predicate, bound_names | [node.param.to_s])
          when Struct
            node.each_pair.flat_map { |_name, value| collect(value, bound_names) }
          when Array
            node.flat_map { |value| collect(value, bound_names) }
          else
            []
          end
        end
      end

      class Analyzer
        STATEFUL_MUTATIONS = %i[append increment decrement multiply clamp remove].freeze

        def self.call(aggregate:, command:) = new(aggregate, command).call

        def initialize(aggregate, command)
          @aggregate = aggregate
          @command = command
          @owner_fields = aggregate.attributes.to_set(&:name)
          @owner_fields << aggregate.lifecycle.field.to_sym if aggregate.lifecycle
          @payload_fields = command.attributes.to_set(&:name)
          @state_reads = Set.new
          @payload_reads = Set.new
          @writes = Set.new
          @known_writes = Set.new
          @unresolved = Set.new
        end

        def call
          analyze_initial_state
          analyze_mutations
          analyze_lifecycle
          analyze_rules(command.givens, phase: :before)
          analyze_rules(command.ensures, phase: :after)
          analyze_rules(aggregate.invariants, phase: :after)
          add_preservation_reads

          complete = unresolved.empty? && owner_fields.subset?(known_writes)
          independent = complete && state_reads.empty?

          Plan.new(
            read_set:                sorted(state_reads),
            write_set:               sorted(writes),
            payload_read_set:        sorted(payload_reads),
            complete_state:          complete,
            state_independent:       independent,
            unresolved_dependencies: unresolved.to_a.sort.freeze
          ).freeze
        end

        private

        attr_reader :aggregate, :command, :owner_fields, :payload_fields,
                    :state_reads, :payload_reads, :writes, :known_writes, :unresolved

        # A fresh Instance supplies these values without reading a stored
        # record. Keep this aligned with Instance.defaults/default_for. They
        # establish completeness but are not command mutations, so they do not
        # appear in write_set.
        def analyze_initial_state
          aggregate.attributes.each do |attribute|
            known_writes << attribute.name if deterministic_initial_value?(attribute)
          end

          known_writes << aggregate.lifecycle.field.to_sym if aggregate.lifecycle
        end

        def deterministic_initial_value?(attribute)
          return true if attribute.list? || attribute.optional? || !attribute.default.nil?
          return false unless aggregate.respond_to?(:value_object)

          value_object = aggregate.value_object(attribute.type)
          value_object&.attributes&.all? { |field| !field.default.nil? }
        end

        def analyze_mutations
          command.mutations.each do |mutation|
            target = mutation.target.to_sym
            writes << target

            unless owner_fields.include?(target)
              unresolved << "mutation target #{target} is not an aggregate field"
              next
            end

            if mutation.op == :set
              known_writes << target if analyze_source?(mutation.source)
            elsif STATEFUL_MUTATIONS.include?(mutation.op)
              state_reads << target
              analyze_source?(mutation.source)
            else
              unresolved << "mutation operation #{mutation.op} has no dependency rule"
            end
          end
        end

        # Returns true only when the source is known without prior aggregate
        # state. Hash sources are the canonical append binding shape.
        def analyze_source?(source)
          case source
          when Symbol
            if payload_fields.include?(source)
              payload_reads << source
              return true
            end
            if owner_fields.include?(source)
              state_reads << source
              return false
            end

            unresolved << "mutation source #{source} has no payload or aggregate field"
            false
          when Hash
            source.values.map { |value| analyze_source?(value) }.all?
          else
            true
          end
        end

        def analyze_lifecycle
          lifecycle = aggregate.lifecycle
          return unless lifecycle

          if command.from
            state_reads << lifecycle.field
          end

          return if lifecycle.transitions_for(command.hecks_name).empty?

          writes << lifecycle.field
          known_writes << lifecycle.field
        end

        def analyze_rules(rules, phase:)
          rules.each do |rule|
            ExpressionReads.paths(rule.canonical).each { |path| classify_path(path, phase) }
          rescue ArgumentError => error
            unresolved << "expression #{rule.canonical.inspect} could not be analyzed: #{error.message}"
          end
        end

        def classify_path(path, phase)
          head, nested = path.split(".", 2)
          name = head.to_sym

          if name == :parent
            parent_field = nested.to_s.split(".", 2).first
            if parent_field.empty? || !owner_fields.include?(parent_field.to_sym)
              unresolved << "#{path} does not name parent aggregate state"
            else
              state_reads << parent_field.to_sym
            end
          elsif name == :old
            old_field = nested.to_s.split(".", 2).first
            if old_field.empty? || !owner_fields.include?(old_field.to_sym)
              unresolved << "#{path} does not name prior aggregate state"
            else
              state_reads << old_field.to_sym
            end
          elsif payload_fields.include?(name)
            payload_reads << name
          elsif owner_fields.include?(name)
            state_reads << name if phase == :before || !known_writes.include?(name)
          else
            unresolved << "expression path #{path} has no payload or aggregate field"
          end
        end

        # A partial mutation must preserve every untouched field on the
        # correctness path. Those prior values are real reads even when no rule
        # names them. A deterministic write needs no preservation read.
        def add_preservation_reads
          state_reads.merge(owner_fields - known_writes)
        end

        def sorted(values) = values.to_a.sort.freeze
      end
    end
  end
end
