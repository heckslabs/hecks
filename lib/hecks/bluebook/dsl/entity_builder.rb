require_relative "word_gate"
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

        # Builds a piece nested under an aggregate (or another piece), threading the owner's
        # value-object and given pools through unchanged so nested pieces share the same state.
        def initialize(name, owner_value_objects: [], owner_named_givens: {},
                       identity_name_prefix: nil, identity_value_object_installer: nil,
                       aggregate_name: nil, chapter_entity_named_givens: {}, chapter_entity_pending_givens: [])
          @name         = name
          @commands     = []
          @queries      = []
          @entities     = []
          @named_givens = {}
          @invariants   = []
          @owner_value_objects = owner_value_objects
          @identity_name_prefix = identity_name_prefix || Naming.demodulise(name)
          @identity_value_object_installer = identity_value_object_installer
          # Threaded unchanged through every nested piece so a sibling's bare given
          # reference can read the same aggregate-wide pool `given_impl` writes to.
          @owner_named_givens = owner_named_givens
          # One level wider than `@owner_named_givens`: the chapter-wide, entity-scoped
          # pool, keyed "Aggregate.Entity" so `#given_impl` can resolve across aggregates.
          @aggregate_name = aggregate_name || Naming.demodulise(name)
          @chapter_entity_named_givens   = chapter_entity_named_givens
          @chapter_entity_pending_givens = chapter_entity_pending_givens
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

        # Declares a rule this piece's own commands must satisfy, or references one a sibling
        # piece anywhere in the chapter already declared.
        #
        # Order doesn't matter: `command` only queues a descriptor here and builds for real at
        # `#drain_pending!` time, after every `given` in this block has already run.
        def given_impl(description, declared_by: nil, &predicate)
          return reference_named_chapter_entity_given(description, declared_by: declared_by) unless predicate

          named = build_rule(Given, description, predicate, owner_name: @name, word: "given",
                              extraction_failure: "its source could not be read, so no other runtime could ever evaluate it")
          @named_givens[description] = named
          # First-declared-wins (`||=`): a second piece under the same aggregate declaring
          # the exact same description independently stays local, never silently overwritten.
          @owner_named_givens[description] ||= named
          # Chapter-wide analogue of the line above, keyed by "Aggregate.Entity" rather than
          # description alone, so two different pieces sharing a description stay distinct
          # candidates a later bare reference chooses between via `declared_by:`.
          @chapter_entity_named_givens[description] ||= {}
          @chapter_entity_named_givens[description]["#{@aggregate_name}.#{@name}"] ||= named
        end

        # Declares a rule every instance of this piece must satisfy — checked per instance,
        # not once against the aggregate's own flat state. No reference-by-name form (unlike
        # `given`); extend that pattern here if cross-piece sharing is ever needed.
        def invariant_impl(description, &predicate)
          @invariants << build_rule(Invariant, description, predicate, owner_name: @name, word: "invariant",
                                     extraction_failure: "it would be a rule the IR cannot carry")
        end

        # Assembles the declared attributes, relationships, nested constructs and rules into an
        # `Entity`.
        def build
          drain_pending!
          resolve_pending_identity!
          seal_lifecycle_guards
          install_closed_sets!
          Entity.declare(
            name:          @name,
            description:   @description,
            identified_by: @identity_paths,
            attributes:    attributes,
            commands:      @commands,
            queries:       @queries,
            entities:      @entities,
            preconditions: @named_givens.values,
            invariants:    @invariants,
            lifecycle:     @lifecycle
          )
        end

        # Evaluates an `entity` block against a fresh builder and returns what it built.
        def self.build(name, owner_value_objects: [], owner_named_givens: {},
                       identity_name_prefix: nil, identity_value_object_installer: nil,
                       aggregate_name: nil, chapter_entity_named_givens: {}, chapter_entity_pending_givens: [], &block)
          builder = new(name, owner_value_objects: owner_value_objects, owner_named_givens: owner_named_givens,
                              identity_name_prefix: identity_name_prefix,
                              identity_value_object_installer: identity_value_object_installer,
                              aggregate_name: aggregate_name,
                              chapter_entity_named_givens: chapter_entity_named_givens,
                              chapter_entity_pending_givens: chapter_entity_pending_givens)
          builder.instance_eval(&block) if block
          builder.build
        end

        private

        # Resolves a bare `given` reference against the chapter-wide, entity-scoped pool.
        # Also writes through to `@owner_named_givens`, not just `@named_givens` — otherwise a
        # sibling piece's own same-aggregate bare reference would never see this resolution.
        def reference_named_chapter_entity_given(description, declared_by:)
          verify_resolves_via!("given", "Entity", "owner_keyed")
          candidates = resolve_owner_keyed(@chapter_entity_named_givens, description)

          named =
            if declared_by
              candidates[declared_by] || pending_chapter_entity_given(description, declared_by: declared_by)
            elsif candidates.size == 1
              candidates.values.first
            elsif candidates.empty?
              pending_chapter_entity_given(description, declared_by: nil)
            else
              raise(Malformed,
                    "#{@aggregate_name}::#{@name}'s given #{description.inspect} is ambiguous " \
                    "across the chapter's own pieces — #{candidates.keys.join(', ')} each declare " \
                    "a DIFFERENT predicate under this same description; name which one with " \
                    "declared_by: (e.g. given(#{description.inspect}, declared_by: " \
                    "#{candidates.keys.first.inspect}))")
            end

          @named_givens[description] = named
          @owner_named_givens[description] ||= named
        end

        # A chapter may be split across files, so an unresolved bare reference defers rather
        # than raising immediately; `BluebookBuilder#resolve_pending_chapter_entity_givens!`
        # fills in the placeholder once every file in the chapter has loaded.
        def pending_chapter_entity_given(description, declared_by:)
          placeholder = Given.new(description: description, canonical: nil, predicate: nil)
          @chapter_entity_pending_givens << { entity: "#{@aggregate_name}.#{@name}", description: description,
                                               declared_by: declared_by, placeholder: placeholder }
          placeholder
        end

        # A piece's own `one_of` synthesizes a closed-set value object, installed onto the
        # owning aggregate so the runtime has it to admit against — not just on the attribute.
        # Two sibling pieces synthesizing the same name install it once; a name collision with
        # a different member list is refused rather than silently kept.
        def install_closed_sets!
          return unless @identity_value_object_installer

          closed_sets.each do |value_object|
            existing = @owner_value_objects.find { |candidate| candidate.hecks_name == value_object.hecks_name }
            if existing
              next if existing.to_h == value_object.to_h

              raise Malformed,
                    "#{@name}'s one_of synthesizes #{value_object.hecks_name.inspect}, but the aggregate already " \
                    "holds a different #{value_object.hecks_name.inspect} — name the closed set's field differently"
            end

            @identity_value_object_installer.call(value_object)
          end
        end

        # Entities are built first, fully, so a nested command's own `append:` can read a
        # sibling piece's `.attributes`; then commands, then queries.
        def drain_pending!
          @entities = @pending_entities.map do |name, block|
            EntityBuilder.build(name, owner_value_objects:             @owner_value_objects,
                                      owner_named_givens:              @owner_named_givens,
                                      identity_name_prefix:            "#{@identity_name_prefix}#{Naming.demodulise(name)}",
                                      identity_value_object_installer: @identity_value_object_installer,
                                      aggregate_name:                  @aggregate_name,
                                      chapter_entity_named_givens:     @chapter_entity_named_givens,
                                      chapter_entity_pending_givens:   @chapter_entity_pending_givens,
                                &block)
          end

          @commands = @pending_commands.map do |name, from, block|
            CommandBuilder.build(name, owner: @name, from: from, named_givens: @named_givens,
                                        owner_attributes: attributes,
                                        owner_constructs: @owner_value_objects + @entities,
                                        entity_shared_givens: @owner_named_givens, &block)
          end

          @queries = @pending_queries.map do |name, block|
            QueryBuilder.build(name, owner_attributes: attributes, &block)
          end
        end

        # Refuses a command that sets the lifecycle field directly, or guards `from:` with no
        # lifecycle declared — a lifecycle field only moves by transition.
        def seal_lifecycle_guards
          @commands.each do |command|
            if @lifecycle && !MetaValidator.shadow_parsing?
              # `delegate`/`corrects` are exempt — the frozen-era-text case, not a live mutation.
              command.mutations.each do |mutation|
                next if [:delegate, :corrects].include?(mutation.op)
                next unless mutation.target.to_sym == @lifecycle.field.to_sym

                raise Malformed,
                      "#{@name}.#{command.hecks_name} sets #{mutation.target}, #{@name}'s lifecycle field — " \
                      "a lifecycle field moves only by transition; declare one instead of setting it"
              end
            end
            next unless command.from
            next if @lifecycle

            raise Malformed,
                  "#{@name}.#{command.hecks_name} guards from: #{Array(command.from).inspect}, but " \
                  "#{@name} declares no lifecycle — from: checks a lifecycle field, and there is " \
                  "none here to check"
          end
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
