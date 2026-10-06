require_relative "word_gate"
require_relative "aggregate_builder/sealing"
require_relative "aggregate_builder/relationships"
require_relative "aggregate_builder/rules"
require_relative "aggregate_builder/draining"
module Hecks
  module Bluebook
    module DSL
      # The `aggregate "Name" do ... end` receiver: collects an aggregate's attributes,
      # entities, commands, queries, policies and rules, and assembles the `Aggregate` IR.
      class AggregateBuilder
        GRAMMAR_CONTEXT = "Aggregate".freeze

        include AttributeCollector
        include IdentityDeclaration
        include RuleReference
        include WordGate
        include Sealing

        # @param name [String] the aggregate's name, as written after `aggregate`
        # @param chapter_named_givens [Hash{String => Hash{String => Bluebook::Given}}] the
        #   chapter-wide given pool, shared and written through by `given_impl`
        # @param chapter_pending_givens [Array<Hash>] unresolved chapter-wide bare given
        #   references, appended to when this aggregate's own reference cannot resolve yet
        # @param chapter_entity_named_givens [Hash{String => Hash{String => Bluebook::Given}}]
        #   the chapter-wide, entity-scoped given pool, threaded unchanged to every entity
        # @param chapter_entity_pending_givens [Array<Hash>] unresolved chapter-wide,
        #   entity-scoped bare given references, threaded unchanged to every entity
        def initialize(name, chapter_named_givens: {}, chapter_pending_givens: [],
                       chapter_entity_named_givens: {}, chapter_entity_pending_givens: [])
          @name = name
          start_declarations
          # Threaded in from `BluebookBuilder#aggregate`; shared chapter-wide across aggregates.
          @chapter_named_givens = chapter_named_givens
          # Threaded chapter-wide; a chapter may span multiple files (see `#pending_chapter_given`)
          @chapter_pending_givens = chapter_pending_givens
          # One level wider than `@chapter_named_givens`: the chapter's entity-scoped pool,
          # passed through unchanged to every entity this aggregate builds.
          @chapter_entity_named_givens   = chapter_entity_named_givens
          @chapter_entity_pending_givens = chapter_entity_pending_givens
        end

        # Sets the human-readable description shown for this aggregate.
        #
        # @param value [String] the description text
        # @return [String] the description as stored
        def description(value)
          @description = value
        end

        # Names where a concept adopted from a canonical source came from.
        #
        # @param from [Object] the canonical source, captured exactly as written
        # @return [Object] `from` as stored
        def provenance_impl(from:)
          @provenance = from
        end

        # Declares this aggregate's own state machine.
        #
        # @param field [Symbol, String] the attribute the state machine lives on
        # @param default [String, Symbol] the state a new record starts in
        # @yield the lifecycle body of `transition` rows, evaluated against a `LifecycleBuilder`
        # @return [Bluebook::Lifecycle] the built state machine
        # @raise [Bluebook::DSL::Malformed] if two transitions for one command overlap
        def lifecycle_impl(field, default:, &)
          @lifecycle = LifecycleBuilder.build(field, default: default, &)
        end

        # Declares a policy scoped to this aggregate, stamping it with the aggregate's own name.
        #
        # @param name [String] the policy's name
        # @yield the policy body, evaluated against a `PolicyBuilder`
        # @return [Array<Bluebook::Policy>] every policy declared so far, this one last
        # @raise [Bluebook::DSL::Malformed] if the body fails any check the policy builder raises
        def policy_impl(name, &)
          reaction = PolicyBuilder.build(name, &)
          reaction.aggregate = @name
          @policies << reaction
        end

        # Declares a value object: a block of `attribute` lines, or (the `type` shorthand) a
        # single `:value` attribute.
        #
        # @param name [String] the value object's name
        # @param type [Module, nil] the bare shorthand's attribute type; exclusive with `block`
        # @yield the `attribute`/`invariant`/`one_of` body; exclusive with `type`
        # @return [Array<Bluebook::ValueObject>] this one, plus any closed sets synthesised
        # @raise [Bluebook::DSL::Malformed] if both `type` and a block are given, or the body fails
        def value_object(name, type = nil, &block)
          refuse_type_and_block!(name, type, block)

          builder = ValueObjectBuilder.new(name, owner_value_objects: @value_objects + closed_sets)
          builder.attribute_impl(:value, type) if type
          builder.instance_eval(&block) if block
          @value_objects << builder.build
          @value_objects.concat(builder.closed_sets)
        end

        # Assembles every declared attribute, construct and rule into an `Aggregate`, after
        # draining pending commands/queries/entities and running every `seal_*` check.
        #
        # @return [Bluebook::Aggregate] the built aggregate
        # @raise [Bluebook::DSL::Malformed] if identity resolution or any `seal_*` check fails —
        #   a mutation or query naming an undeclared field, an inconsistent default, a lifecycle
        #   guard with no lifecycle, a lifecycle-field mutation outside a transition, a projected
        #   field naming an undeclared reference, or a correction targeting an unreferenced field
        def build
          drain_pending!
          resolve_pending_identity!
          seal_all

          ir = Aggregate.new(**aggregate_shape, **aggregate_rules)

          # On purpose, after the IR exists: the object the IR graph should know is `ir`,
          # not this builder.
          stamp_references(ir)
          ir
        end

        # Evaluates an `aggregate` block against a fresh builder and returns the built aggregate.
        # The `chapter_*` params thread the chapter-wide and entity-scoped given pools through.
        #
        # @yield the aggregate body, evaluated with the builder as `self`; may be omitted
        # @return [Bluebook::Aggregate] the built aggregate
        # @raise [Bluebook::DSL::Malformed] if the body fails any check `#build` raises
        def self.build(name, chapter_named_givens: {}, chapter_pending_givens: [],
                       chapter_entity_named_givens: {}, chapter_entity_pending_givens: [], &block)
          builder = new(name, chapter_named_givens: chapter_named_givens, chapter_pending_givens: chapter_pending_givens,
                              chapter_entity_named_givens: chapter_entity_named_givens,
                              chapter_entity_pending_givens: chapter_entity_pending_givens)
          builder.instance_eval(&block) if block
          builder.build
        end

        private

        def start_declarations
          @value_objects     = []
          @invariants        = []
          @named_givens      = {}
          @projected_fields  = []
          @identity_paths    = []
          @policies          = []
          @reference_targets = []
          start_pending
        end

        def start_pending
          # Shared unchanged with every entity/command this aggregate builds (see `#entity_impl`).
          @entity_named_givens = {}
          # `entity`/`command`/`query` queue a descriptor here instead of building eagerly
          # (see `#drain_pending!`).
          @pending_entities = []
          @pending_commands = []
          @pending_queries  = []
          @entities = []
          @commands = []
          @queries  = []
        end

        def refuse_type_and_block!(name, type, block)
          return unless type && block

          raise Malformed,
                "#{name} declares both a type (#{type.inspect}) and a block — " \
                "value_object #{name.inspect}, Type is sugar for a block declaring " \
                "exactly one attribute named :value; write one form or the other, never both"
        end

        # The aggregate's name and the state it holds.
        def aggregate_shape
          { name: @name, description: @description, attributes: attributes,
            value_objects: @value_objects + closed_sets, identified_by: @identity_paths,
            lifecycle: @lifecycle, entities: @entities, provenance: @provenance }
        end

        # What the aggregate does and the rules it keeps.
        def aggregate_rules
          { commands: @commands, invariants: @invariants, preconditions: @named_givens.values,
            projected_fields: @projected_fields, queries: @queries, policies: @policies,
            reference_targets: @reference_targets + entity_reference_targets }
        end

        # `identified_by`'s resolution pool: an aggregate resolves a bare field's value-object
        # type against its own attributes and inline closed sets.
        def identity_pool = @value_objects + closed_sets

        def identity_value_object_name = "#{Naming.demodulise(@name)}Identity"

        def install_identity_value_object!(value_object)
          @value_objects << value_object
        end
      end
    end
  end
end
