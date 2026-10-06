require_relative "word_gate"
require_relative "aggregate_builder/sealing"
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
          @name          = name
          @value_objects = []
          @commands      = []
          @invariants    = []
          @named_givens  = {}
          @projected_fields = []
          @identity_paths = []
          @entities      = []
          @queries       = []
          @policies      = []
          @reference_targets = []
          # Shared unchanged with every entity/command this aggregate builds (see `#entity_impl`).
          @entity_named_givens = {}
          # Threaded in from `BluebookBuilder#aggregate`; shared chapter-wide across aggregates.
          @chapter_named_givens = chapter_named_givens
          # Threaded chapter-wide; a chapter may span multiple files (see `#pending_chapter_given`)
          @chapter_pending_givens = chapter_pending_givens
          # One level wider than `@chapter_named_givens`: the chapter's entity-scoped pool,
          # passed through unchanged to every entity this aggregate builds.
          @chapter_entity_named_givens   = chapter_entity_named_givens
          @chapter_entity_pending_givens = chapter_entity_pending_givens
          # `entity`/`command`/`query` queue a descriptor here instead of building eagerly
          # (see `#drain_pending!`).
          @pending_entities = []
          @pending_commands = []
          @pending_queries  = []
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

        # Declares a reference from this aggregate's own head to another aggregate's identity.
        #
        # @param type [Module, Symbol, String] the referenced aggregate, written as a bare
        #   constant
        # @param as [Symbol, nil] the attribute's name; nil derives it from `type`
        # @param optional [Boolean] whether the reference may be absent
        # @return [void]
        # @raise [Bluebook::DSL::Malformed] if `as` (or the derived name) is already declared
        def reference_to_impl(type, as: nil, optional: false)
          target = Naming.demodulise(type)
          @reference_targets << target
          relationship_attribute(target, :reference_to,
                                 as || default_reference_name(target), optional: optional)
        end

        # Declares that this aggregate holds its own kept-fresh copy of a field reached through
        # a reference, so a rule can read it locally instead of reaching across the boundary.
        #
        # `from:` names the local reference, not the target aggregate, so two references to the
        # same aggregate can each carry their own projection.
        #
        # @param name [Symbol, String] the local field receiving the projected remote value
        # @param from [Symbol, String] the local reference and remote field, dotted, such as
        #   `:"customer.status"`
        # @return [Array<Bluebook::ProjectedField>] every projected field declared so far, this
        #   one last
        # @raise [Bluebook::DSL::Malformed] if `from` is not `reference.field` shaped
        def projects_impl(name, from:)
          reference, _, remote_field = from.to_s.rpartition(".")

          if reference.empty? || remote_field.empty?
            raise Malformed,
                  "#{@name}.projects :#{name} names #{from.inspect}, which is not " \
                  "reference.field — say which reference and which field on it, e.g. " \
                  "from: :\"customer.status\""
          end

          @projected_fields << ProjectedField.new(name: name.to_sym, reference: reference.to_sym,
                                                  remote_field: remote_field.to_sym)
        end

        # Declares a list-typed relationship to another aggregate, referenced by its plural name.
        #
        # Under `MetaValidator.shadow_parsing?`, routes to the collapsing single-reference
        # form instead, so frozen era text keeps its original meaning.
        #
        # @param type [Module, Symbol, String] the related aggregate's plural name, a bare constant
        # @param as [Symbol, nil] the attribute's name; nil derives it from `type`
        # @param legacy_options [Hash] must be empty outside shadow-parsing; under
        #   shadow-parsing, `:optional` is read for the legacy single-reference form
        # @return [void]
        # @raise [Bluebook::DSL::Malformed] outside shadow-parsing, if non-empty, or if the
        #   derived name is already declared
        def has_many_impl(type, as: nil, **legacy_options)
          return legacy_has_many(type, as: as, optional: legacy_options.fetch(:optional, false)) if MetaValidator.shadow_parsing?

          unless legacy_options.empty?
            raise Malformed,
                  "#{@name}.has_many takes no #{legacy_options.keys.first}: — an empty list already means none"
          end

          plural = Naming.demodulise(type)
          target = Naming.singularize(plural)
          @reference_targets << target
          relationship_attribute(target, :has_many, as || Naming.snake(plural).to_sym,
                                 list: true)
        end

        # Declares a single-valued relationship this aggregate holds toward another.
        #
        # @param type [Module, Symbol, String] the related aggregate, a bare constant
        # @param as [Symbol, nil] the attribute's name; nil derives it from `type`
        # @param optional [Boolean] whether the relationship may be absent
        # @return [void]
        def has_one_impl(type, as: nil, optional: false)
          return legacy_has_one(type, as: as, optional: optional) if MetaValidator.shadow_parsing?

          target = Naming.demodulise(type)
          @reference_targets << target
          relationship_attribute(target, :has_one, as || Naming.snake(target).to_sym,
                                 optional: optional)
        end

        # Declares a single-valued relationship toward the aggregate that owns this one.
        #
        # @param type [Module, Symbol, String] the owning aggregate, a bare constant
        # @param as [Symbol, nil] the attribute's name; nil derives it from `type`
        # @param optional [Boolean] whether the relationship may be absent
        # @return [void]
        def belongs_to_impl(type, as: nil, optional: false)
          return legacy_has_one(type, as: as, optional: optional) if MetaValidator.shadow_parsing?

          target = Naming.demodulise(type)
          @reference_targets << target
          relationship_attribute(target, :belongs_to, as || Naming.snake(target).to_sym,
                                 optional: optional)
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

        # Queues a piece nested in this aggregate, built later once every sibling has been seen.
        #
        # @param name [String] the nested piece's name
        # @yield the piece body, evaluated against an `EntityBuilder` once drained
        # @return [Array<Array>] every pending piece queued so far, this one last
        def entity_impl(name, &block)
          @pending_entities << [name, block]
        end

        # Queues a query declared on this aggregate, built later once every sibling has been seen.
        #
        # @param name [String] the query's name
        # @yield the query body, evaluated against a `QueryBuilder` once drained
        # @return [Array<Array>] every pending query queued so far, this one last
        def query_impl(name, &block)
          @pending_queries << [name, block]
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
          if type && block
            raise Malformed,
                  "#{name} declares both a type (#{type.inspect}) and a block — " \
                  "value_object #{name.inspect}, Type is sugar for a block declaring " \
                  "exactly one attribute named :value; write one form or the other, never both"
          end

          builder = ValueObjectBuilder.new(name, owner_value_objects: @value_objects + closed_sets)
          builder.attribute_impl(:value, type) if type
          builder.instance_eval(&block) if block
          @value_objects << builder.build
          @value_objects.concat(builder.closed_sets)
        end

        # Queues a command declared on this aggregate, built later once every sibling has been
        # seen.
        #
        # `from:` is checked against this aggregate's own lifecycle field, never a target
        # state or transition, so a guard can't drift out of sync with the state machine.
        #
        # @param name [String] the command's name
        # @param from [String, Symbol, Array<String, Symbol>, nil] the lifecycle state(s) this
        #   command guards from; nil admits from any state
        # @yield the command body, evaluated against a `CommandBuilder` once drained
        # @return [Array<Array>] every pending command queued so far, this one last
        def command_impl(name, from: nil, &block)
          # Owner is stamped once `Aggregate#initialize` runs; an entity's own commands are
          # owned by the entity instead.
          @pending_commands << [name, from, block]
        end

        # Declares a rule this aggregate's own commands must satisfy, or references a sibling's.
        # `declared_by:` disambiguates a bare reference when two aggregates share a description.
        #
        # @param description [String] the rule's description; also its name for a sibling reference
        # @param declared_by [Module, Symbol, String, nil] which aggregate's rule; only meaningful
        #   with no block
        # @yield the predicate body; evaluated for its extracted source, never called directly
        # @return [void]
        # @raise [Bluebook::DSL::Malformed] if the source can't be extracted, or a bare reference
        #   resolves to none or more than one candidate once the chapter has loaded
        def given_impl(description, declared_by: nil, &predicate)
          return reference_named_chapter_given(description, declared_by: declared_by) unless predicate

          named = build_rule(Given, description, predicate, owner_name: @name, word: "given",
                              extraction_failure: "its source could not be read, so no other runtime could ever evaluate it")
          @named_givens[description] = named
          # Keyed by [description, this aggregate's name] so two aggregates sharing a
          # description are distinct candidates, never merged into one slot.
          @chapter_named_givens[description] ||= {}
          @chapter_named_givens[description][@name] ||= named
        end

        private

        # Unresolved (no candidate yet) doesn't raise here — a chapter split across files
        # may still declare this precondition in a later file (see `#pending_chapter_given`).
        def reference_named_chapter_given(description, declared_by:)
          verify_resolves_via!("given", "Aggregate", "owner_keyed")
          candidates = resolve_owner_keyed(@chapter_named_givens, description)

          named =
            if declared_by
              owner = Naming.demodulise(declared_by)
              candidates[owner] || pending_chapter_given(description, declared_by: owner)
            elsif candidates.size == 1
              candidates.values.first
            elsif candidates.empty?
              pending_chapter_given(description, declared_by: nil)
            else
              raise(Malformed,
                    "#{@name}'s given #{description.inspect} is ambiguous in this chapter — " \
                    "#{candidates.keys.join(", ")} each declare a DIFFERENT predicate under " \
                    "this same description; name which one with declared_by: (e.g. " \
                    "given(#{description.inspect}, declared_by: #{candidates.keys.first}))")
            end

          @named_givens[description] = named
        end

        # Returns a placeholder `Given`, embedded by reference in this aggregate's IR;
        # `BluebookBuilder#resolve_pending_chapter_givens!` mutates it in place once the
        # whole chapter loads, so every existing reference sees the resolved fields together.
        def pending_chapter_given(description, declared_by:)
          placeholder = Given.new(description: description, canonical: nil, predicate: nil)
          @chapter_pending_givens << { aggregate: @name, description: description,
                                        declared_by: declared_by, placeholder: placeholder }
          placeholder
        end

        public

        # Declares a rule the whole aggregate must satisfy, checked after every command, before
        # save.
        #
        # @param description [String] the rule's description
        # @yield the predicate body; evaluated for its extracted source, never called directly
        # @return [void]
        # @raise [Bluebook::DSL::Malformed] if the block's source could not be extracted
        def invariant_impl(description, &predicate)
          @invariants << build_rule(Invariant, description, predicate, owner_name: @name, word: "invariant",
                                     extraction_failure: "it would be a rule the IR cannot carry")
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
          seal_mutation_targets
          seal_query_targets
          seal_defaults
          seal_lifecycle_guards
          seal_projected_fields
          seal_correction_targets

          ir = Aggregate.new(
            name:              @name,
            description:       @description,
            attributes:        attributes,
            value_objects:     @value_objects + closed_sets,
            commands:          @commands,
            invariants:        @invariants,
            preconditions:     @named_givens.values,
            projected_fields:  @projected_fields,
            identified_by:     @identity_paths,
            lifecycle:         @lifecycle,
            entities:          @entities,
            queries:           @queries,
            policies:          @policies,
            reference_targets: @reference_targets + entity_reference_targets,
            provenance:        @provenance
          )

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

        # Deferred: entity/command/query queue a descriptor instead of building eagerly, so a
        # later-declared piece can still be referenced from an earlier line. Entities drain
        # first and fully — a command's own `sets` may need an entity's attributes already built.
        def drain_pending!
          @entities = @pending_entities.map do |name, block|
            EntityBuilder.build(name, owner_value_objects:             @value_objects + closed_sets,
                                      owner_named_givens:              @entity_named_givens,
                                      identity_name_prefix:            "#{Naming.demodulise(@name)}#{Naming.demodulise(name)}",
                                      identity_value_object_installer: ->(value_object) { @value_objects << value_object },
                                      aggregate_name:                  @name,
                                      chapter_entity_named_givens:     @chapter_entity_named_givens,
                                      chapter_entity_pending_givens:   @chapter_entity_pending_givens,
                                &block)
          end

          @commands = @pending_commands.map do |name, from, block|
            CommandBuilder.build(name, owner: @name, from: from, named_givens: @named_givens,
                                        owner_attributes: attributes,
                                        owner_constructs: @value_objects + closed_sets + @entities, &block)
          end

          @queries = @pending_queries.map do |name, block|
            QueryBuilder.build(name, owner_attributes: attributes, &block)
          end
        end

        # `identified_by`'s resolution pool: an aggregate resolves a bare field's value-object
        # type against its own attributes and inline closed sets.
        def identity_pool = @value_objects + closed_sets

        def identity_value_object_name = "#{Naming.demodulise(@name)}Identity"

        def install_identity_value_object!(value_object)
          @value_objects << value_object
        end

        # Shadow-parsing's collapsing behavior for has_many/has_one/belongs_to.
        def legacy_has_many(type, as:, optional: false)
          plural = Naming.demodulise(type)
          reference_to_impl(Naming.singularize(plural), as: as || Naming.snake(plural).to_sym, optional: optional)
        end

        def legacy_has_one(type, as:, optional: false)
          reference_to_impl(type, as: as || Naming.snake(Naming.demodulise(type)).to_sym, optional: optional)
        end
      end
    end
  end
end
