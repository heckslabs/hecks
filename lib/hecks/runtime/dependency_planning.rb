require_relative "../bluebook/expression"

module Hecks
  module Runtime
    # Persistence-neutral facts derived from a command's semantic IR; it plans, never executes.
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
        # Whether every owner field this command could touch is a known, deterministic write.
        #
        # @return [Boolean] `complete_state`
        def complete_state? = complete_state

        # Whether the command needs no prior state at all (implies `complete_state?`).
        #
        # @return [Boolean] `state_independent`
        def state_independent? = state_independent

        # Chooses the dispatch strategy the plan's proof and the adapter's capabilities allow.
        # An optimization is selected only when both are present.
        #
        # @param capabilities [Array<String, Symbol>] the repository's declared capabilities
        # @return [Symbol] `DependencyPlanning::ATOMIC_PUT` when the plan is complete,
        #   state-independent, and the adapter declares that capability;
        #   `DependencyPlanning::TRANSACTIONAL_FALLBACK` otherwise
        def strategy_for(capabilities: [])
          return TRANSACTIONAL_FALLBACK unless complete_state? && state_independent?
          return TRANSACTIONAL_FALLBACK unless capabilities.map(&:to_sym).include?(ATOMIC_PUT)

          ATOMIC_PUT
        end
      end

      # Collects the dotted paths a canonical expression reads, without evaluating it.
      # Used by Analyzer to classify rule dependencies.
      module ExpressionReads
        module_function

        # Finds every dotted path a canonical expression reads.
        #
        # Walks the parsed nodes the evaluator uses; only Lookup nodes carry dependencies.
        #
        # @param canonical [String] the canonical expression text
        # @return [Array<String>] the dotted paths the expression reads
        def paths(canonical)
          collect(Bluebook::Expression::Evaluator.parse(canonical), Set.new)
        end

        # Walks one parsed node, skipping names bound by an enclosing block predicate.
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

      # Static dependency analysis for one command: derives a Plan without executing it.
      # CommandInterpreter and EntityInterpreter consult it before choosing a dispatch strategy.
      class Analyzer
        STATEFUL_MUTATIONS = %i[append increment decrement multiply clamp remove].freeze

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
          @owner_fields = aggregate.attributes.to_set(&:name)
          @owner_fields << aggregate.lifecycle.field.to_sym if aggregate.lifecycle
          @root_owner_fields = root_aggregate.attributes.to_set(&:name)
          @root_owner_fields << root_aggregate.lifecycle.field.to_sym if root_aggregate.lifecycle
          # `projects` fields are owner state: a rule reading one reads this record's stored
          # field. Left out of `known_writes` so `add_preservation_reads` keeps it as a read;
          # the interpreter reseeds it on save. `parent.*` reads may name the root's too.
          aggregate.projected_fields.each { |field| @owner_fields << field.name } if aggregate.respond_to?(:projected_fields)
          if root_aggregate.respond_to?(:projected_fields)
            root_aggregate.projected_fields.each do |field|
              @root_owner_fields << field.name
            end
          end
          @payload_fields = command.attributes.to_set(&:name)
          @state_reads = Set.new
          @payload_reads = Set.new
          @writes = Set.new
          @known_writes = Set.new
          @unresolved = Set.new
        end

        # Runs the analysis and derives the command's dependency plan.
        #
        # @return [Hecks::Runtime::DependencyPlanning::Plan] the derived, frozen plan
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

        attr_reader :aggregate, :command, :owner_fields, :root_owner_fields, :payload_fields,
                    :state_reads, :payload_reads, :writes, :known_writes, :unresolved

        # A fresh Instance supplies these values without a stored record; keep aligned with
        # Instance.defaults/default_for. They are not command mutations, so not in write_set.
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

        # True only when the source is known without prior state. Hash sources are append bindings.
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

          state_reads << lifecycle.field if command.from

          return if lifecycle.transitions_for(command.hecks_name).empty?

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

          if name == :parent
            # `parent.X` names the root aggregate's field, not the entity's `owner_fields`;
            # the two sets are identical for a plain aggregate command.
            resolve_nested_state_read!(path, nested, root_owner_fields, "does not name parent aggregate state")
          elsif name == :old
            resolve_nested_state_read!(path, nested, owner_fields, "does not name prior aggregate state")
          elsif payload_fields.include?(name)
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

        def sorted(values) = values.to_a.sort.freeze
      end
    end
  end
end
