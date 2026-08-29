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

      # Walks a canonical expression's parsed nodes (the same AST
      # Bluebook::Expression::Evaluator evaluates) and collects the
      # dotted paths it reads — used by Analyzer to classify a
      # given/ensures/invariant rule's dependencies without evaluating it.
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

      # Static, correctness-first dependency analysis for one command:
      # walks its mutations, lifecycle transitions, and given/ensures/
      # invariant rules to derive a Plan (read_set/write_set/
      # complete_state?/state_independent?) describing what the command
      # touches without executing it. `Analyzer.call` is what
      # CommandInterpreter and EntityInterpreter both consult before
      # choosing a dispatch strategy.
      class Analyzer
        STATEFUL_MUTATIONS = %i[append increment decrement multiply clamp remove].freeze

        # `root_aggregate:` — Wave 8's own audit surfaced a real bug here,
        # not merely a missing feature: for an ENTITY-owned command,
        # `EntityInterpreter` calls this with `aggregate:` set to the
        # ENTITY itself (`element_interpreter.rb`'s own `Analyzer.call
        # (aggregate: entity, command:)`), so `owner_fields` was always
        # the entity's own attribute set. A `given`/`ensures` reading
        # `parent.X` legitimately means the ROOT aggregate's own field —
        # a genuinely different owner — but `classify_path`'s `:parent`
        # branch checked that read against `owner_fields` (the entity's),
        # which can never contain a root-level field, so every entity
        # command with a real, legitimate `parent.*` read was refused as
        # unresolved regardless of correctness. Defaults to `aggregate`
        # (a no-op) for the plain-aggregate case — `CommandInterpreter`'s
        # own call site never needed to change.
        def self.call(aggregate:, command:, root_aggregate: aggregate) = new(aggregate, command, root_aggregate).call

        def initialize(aggregate, command, root_aggregate = aggregate)
          @aggregate = aggregate
          @command = command
          @owner_fields = aggregate.attributes.to_set(&:name)
          @owner_fields << aggregate.lifecycle.field.to_sym if aggregate.lifecycle
          @root_owner_fields = root_aggregate.attributes.to_set(&:name)
          @root_owner_fields << root_aggregate.lifecycle.field.to_sym if root_aggregate.lifecycle
          # `projects` FIELDS (S12, ADR 0025) ARE OWNER STATE TOO — a
          # `given`/`ensures` reading one (e.g. `customer_status ==
          # "active"`) is reading this record's own stored field, same
          # as any attribute, even though nothing here WRITES it via a
          # declared mutation (`CommandInterpreter#seed_projected_fields`
          # populates it outside this analysis entirely). Left out of
          # `known_writes` deliberately: `add_preservation_reads` then
          # correctly treats it as a prior-state read that must survive
          # a partial mutation, which is exactly right — a projected
          # field's freshness comes from the interpreter reseeding it on
          # save, not from anything a caller-supplied write set carries.
          # Applies to BOTH `owner_fields` and `root_owner_fields` — an
          # entity's own `parent.*` read can name the root aggregate's
          # projected field just as easily as one of its real attributes
          # (`Banking::Withdrawal.Dispute`'s own `parent.account_customer_
          # status`, ATMCard's projected field, is a real, live example).
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

        # KNOWN, HARMLESS GAP: `corrects ..., as: :name`'s bound name
        # (admissibility.rb's `enforce_correction_target`/`enforce_givens`/
        # `enforce_ensures`) isn't special-cased here the way `:old`/
        # `:parent` are — a given/ensures referencing it falls through to
        # `unresolved` below (its own field lookup finds no owner/payload
        # match), same net effect as any other not-yet-optimized command:
        # `complete_state?` comes back false, so dispatch takes the safe
        # `hydrate_existing` path instead of the `ATOMIC_PUT` fast path.
        # Not a correctness bug — `as:`'s runtime binding (a plain `attrs`
        # merge, exactly like `old:`'s) resolves and evaluates correctly
        # regardless of what this STATIC analysis concludes — just a real,
        # deliberately-left optimization gap: closing it would mean
        # threading "which names this command declares as correction
        # bindings" into the Analyzer, which doesn't have that per-command
        # context today. Worth doing alongside `:old`/`:parent`'s own
        # handling someday, not attempted here.
        def classify_path(path, phase)
          head, nested = path.split(".", 2)
          name = head.to_sym

          if name == :parent
            # `root_owner_fields` — NOT `owner_fields`. For an entity-owned
            # command `owner_fields` is the ENTITY's own attribute set;
            # `parent.X` always means the ROOT aggregate's own field, a
            # genuinely different owner (`root_aggregate:`'s own header,
            # above, has the full bug this fixes). Identical for a plain
            # aggregate command, where root_aggregate defaults to aggregate
            # itself and the two sets are the same set.
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

        # Shared shape behind the `:parent`/`:old` branches above: read the
        # nested field name, check it against the given owner field set
        # (deliberately different sets for `parent`/`old` — see the caller),
        # and either record it as a state read or refuse with `message`.
        def resolve_nested_state_read!(path, nested, field_set, message)
          field = nested.to_s.split(".", 2).first
          if field.empty? || !field_set.include?(field.to_sym)
            unresolved << "#{path} #{message}"
          else
            state_reads << field.to_sym
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
