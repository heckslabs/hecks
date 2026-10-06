require_relative "word_gate"
require_relative "entity_builder/scope"
require_relative "entity_builder/rules"
require_relative "entity_builder/sealing"
module Hecks
  module Bluebook
    module DSL
      # Parses an `entity "Name" do ... end` block into an `Entity` — attributes, relationships,
      # nested commands/queries/lifecycle, and preconditions shared across them (ADR 0026).
      class EntityBuilder
        GRAMMAR_CONTEXT = "Entity".freeze

        include AttributeCollector
        include IdentityDeclaration
        include RuleReference
        include WordGate
        include Rules
        include Sealing

        # Builds a piece nested under an aggregate (or another piece), threading the owner's
        # value-object and given pools through unchanged so nested pieces share the same state.
        #
        # @param name [String] the piece's name
        # @param context [Hash] what the owner hands down (see `Scope`)
        # @raise [ArgumentError] on an unknown keyword
        def initialize(name, **context)
          @name         = name
          @commands     = []
          @queries      = []
          @entities     = []
          @named_givens = {}
          @invariants   = []
          adopt_scope(name, Scope.from(**context))
          # Deferred: built once every sibling in this block has been seen, so a nested
          # command can resolve a sibling entity/command/query declared later in the block.
          @pending_entities = []
          @pending_commands = []
          @pending_queries  = []
        end

        # Sets the human-readable description shown for this entity.
        def description(value) = @description = value

        # Declares a reference from this piece to another aggregate's identity — never to
        # another piece, since this language has no cross-piece addressing to resolve one against.
        def reference_to_impl(type, as: nil, optional: false)
          target = Naming.demodulise(type)
          relationship_attribute(target, :reference_to,
                                 as || default_reference_name(target), optional: optional)
        end

        # `has_many_impl`/`has_one_impl` are DSL keywords (`has_many`/`has_one` in a bluebook),
        # not real predicates, so Naming/PredicatePrefix does not apply here.
        # rubocop:disable Naming/PredicatePrefix
        # Declares a list-typed relationship to another entity, referenced by its plural name.
        def has_many_impl(type, as: nil, **options)
          unless options.empty?
            raise Malformed,
                  "#{@name}.has_many takes no #{options.keys.first}: — an empty list already means none"
          end

          plural = Naming.demodulise(type)
          relationship_attribute(Naming.singularize(plural), :has_many,
                                 as || Naming.snake(plural).to_sym, list: true)
        end

        # Declares a single-valued relationship to another entity.
        def has_one_impl(type, as: nil, optional: false)
          target = Naming.demodulise(type)
          relationship_attribute(target, :has_one, as || Naming.snake(target).to_sym, optional: optional)
        end
        # rubocop:enable Naming/PredicatePrefix

        # Declares a single-valued relationship to the entity that owns this one.
        def belongs_to_impl(type, as: nil, optional: false)
          target = Naming.demodulise(type)
          relationship_attribute(target, :belongs_to, as || Naming.snake(target).to_sym, optional: optional)
        end

        # `identified_by` (from AttributeCollector) names the scalar field that is this
        # piece's identity, including composite identity, the same as an aggregate's own.

        # Queues a command declared on this piece, built later once every sibling has been seen.
        def command_impl(name, from: nil, &block)
          @pending_commands << [name, from, block]
        end

        # Queues a query declared on this piece, built later once every sibling has been seen.
        def query_impl(name, &block)
          @pending_queries << [name, block]
        end

        # Queues a piece nested inside this one, built later once every sibling has been seen.
        # `owner_value_objects` passes through unchanged since a piece mints none of its own.
        def entity_impl(name, &block)
          @pending_entities << [name, block]
        end

        # Declares this piece's own state machine.
        def lifecycle_impl(field, default:, &)
          @lifecycle = LifecycleBuilder.build(field, default: default, &)
        end

        # Assembles the declared attributes, relationships, nested constructs and rules into an
        # `Entity`.
        def build
          drain_pending!
          resolve_pending_identity!
          seal_lifecycle_guards
          install_closed_sets!
          Entity.declare(**entity_fields)
        end

        # Evaluates an `entity` block against a fresh builder and returns what it built.
        #
        # @param name [String] the piece's name
        # @param context [Hash] what the owner hands down (see `Scope`)
        # @yield the entity body, evaluated with the builder as `self`; may be omitted
        # @return [Bluebook::Entity] the built entity
        def self.build(name, **context, &block)
          builder = new(name, **context)
          builder.instance_eval(&block) if block
          builder.build
        end

        private

        def adopt_scope(name, scope)
          @owner_value_objects = scope.owner_value_objects
          @identity_name_prefix = scope.identity_name_prefix || Naming.demodulise(name)
          @identity_value_object_installer = scope.identity_value_object_installer
          # Threaded unchanged through every nested piece so a sibling's bare given
          # reference can read the same aggregate-wide pool `given_impl` writes to.
          @owner_named_givens = scope.owner_named_givens
          # One level wider than `@owner_named_givens`: the chapter-wide, entity-scoped
          # pool, keyed "Aggregate.Entity" so `#given_impl` can resolve across aggregates.
          @aggregate_name = scope.aggregate_name || Naming.demodulise(name)
          @chapter_entity_named_givens   = scope.chapter_entity_named_givens
          @chapter_entity_pending_givens = scope.chapter_entity_pending_givens
        end

        def entity_fields
          { name: @name, description: @description, identified_by: @identity_paths,
            attributes: attributes, commands: @commands, queries: @queries, entities: @entities,
            preconditions: @named_givens.values, invariants: @invariants, lifecycle: @lifecycle }
        end

        # A piece mints no value objects of its own, so `identified_by` resolves a bare field's
        # type against the owner aggregate's pool, passed in at declaration.
        def identity_pool = @owner_value_objects

        def identity_value_object_name = "#{@identity_name_prefix}Identity"

        def install_identity_value_object!(value_object)
          @identity_value_object_installer&.call(value_object)
          @owner_value_objects << value_object unless @owner_value_objects.include?(value_object)
        end
      end
    end
  end
end
