module Hecks
  module Bluebook
    module MetaValidator
      # The language's own self-description, read back as a walkable structure:
      # which command appends to which list, and how the containment tree nests.
      class Plan
        # One append command: the verb, and the value-object-field -> argument map.
        # `:map` shadows Enumerable#map on purpose; spec/plan_spec.rb asserts on it.
        # rubocop:disable-next Lint/StructNewOverride
        Append = Struct.new(:verb, :map, keyword_init: true)

        # One setting command. `targets` is target -> argument ; Lifecycle sets two
        # fields in a single command, so it is a map rather than a pair.
        Setter = Struct.new(:verb, :targets, keyword_init: true)

        Category = Struct.new(:name, :declare, :parent, :parent_key, :fields,
                              :appends, :alternates, :setters, :sealers, :references,
                              :identity_paths, :entity_owned,
                              keyword_init: true) do
          # Every verb this category declares, in declaration order; a verb missing
          # here is one the coverage gate stops watching.
          #
          # @return [Array<String>] every command name this category declares
          #   (the creating command, every setter, appender, alternate
          #   appender, and sealer), `nil` entries dropped
          def verbs
            [declare, *setters.map(&:verb), *appends.values.map(&:verb),
             *alternates.map(&:verb), *sealers].compact
          end

          # Whether `argument` on `verb` carries an ID rather than a value.
          #
          # @param verb [String] the command name declaring `argument`
          # @param argument [String] the argument name to check
          # @return [Boolean] whether `argument` on `verb` is a reference
          def references?(verb, argument)
            Array(references[verb.to_s]).include?(argument.to_s)
          end

          # Whether this category has no parent — the root of the containment tree.
          def root? = parent.nil?
        end

        # Reads the language's own self-description off `registry`.
        #
        # @param registry [Runtime::Registry] a registry with the language's
        #   own "Bluebook" chapter already judged and assembled
        # @return [Plan] the plan, built from that chapter's own aggregates
        def self.for(registry)
          new(registry.bluebook("Bluebook"))
        end

        attr_reader :categories

        # @param meta [Bluebook::Chapter] the language's own assembled
        #   "Bluebook" chapter
        def initialize(meta)
          @categories = {}
          meta.aggregates.each do |aggregate|
            # Vocabulary declares no commands — it is static declaration read from
            # the IR by spec/vocabulary_conformance_spec, never dispatched. It needs
            # no special case: a category with nothing to offer contributes nothing.
            next if aggregate.commands.empty?

            @categories[aggregate.hecks_name] = read(aggregate)

            # Member, Handler and Dispatch are entities nested under their
            # owning aggregate (ADR 0026), so `meta.aggregates` alone never
            # finds them; `add_nested_entities` walks each aggregate's own
            # `.entities`, recursing (Dispatch nests inside Handler inside
            # ProcessManager), with `entity_owned: true` marking that this
            # category has no top-level aggregate a bare verb can dispatch into.
            add_nested_entities(aggregate)
          end
          @categories.freeze
        end

        # Looks up one category by name.
        #
        # @param name [String, Symbol] the category name, such as
        #   `"Command"` or `"ValueObject"`
        # @return [Category, nil] the named category, or `nil` if the
        #   language declares no such category
        def category(name) = @categories[name.to_s]

        # Lists every category this plan holds.
        #
        # @return [Array<String>] every category name this plan holds
        def names          = @categories.keys

        # Every verb the language declares, spelled as the judge would
        # dispatch it — entity-owned categories dotted to match `Judge#verb_for`.
        #
        # @return [Array<String>] every verb the language declares, dotted
        #   and prefixed with `"Bluebook::"`, such as `"Bluebook::Aggregate.
        #   Command.Argument"`
        def verbs
          @categories.flat_map do |name, category|
            category.verbs.map { |verb| "Bluebook::#{dotted_prefix(name)}.#{verb}" }
          end
        end

        private

        # Recurses to handle ADR 0026's two-level entity chain (Dispatch inside
        # Handler inside ProcessManager).
        def add_nested_entities(owner)
          owner.entities.each do |entity|
            next if entity.commands.empty?

            @categories[entity.hecks_name] = read(entity, owner: owner.hecks_name, entity_owned: true)
            add_nested_entities(entity)
          end
        end

        # Mirrors `Judge#dotted_prefix` exactly; must agree for entity-owned categories.
        def dotted_prefix(name)
          found = category(name)
          return name unless found&.entity_owned

          "#{dotted_prefix(found.parent)}.#{name}"
        end

        # `owner` is passed in explicitly: an entity's own creating command
        # never carries a `reference_to` argument to derive it from.
        def read(aggregate, owner: nil, entity_owned: false)
          # entity_owned skips declaration_command: an entity's own commands
          # never carry `reference_to`, so it would misidentify one as creating.
          declare    = entity_owned ? nil : declaration_command(aggregate)
          parent     = parent_relationship_of(aggregate)
          parent_key = owner ? "aggregate" : parent&.name&.to_s
          rest       = aggregate.commands - [declare].compact

          Category.new(
            name:           aggregate.hecks_name,
            declare:        declare&.hecks_name,
            parent:         owner || parent&.type&.target_name,
            parent_key:     parent_key,
            fields:         declared_fields(declare),
            appends:        appends_in(rest),
            alternates:     alternates_in(rest),
            setters:        setters_in(rest),
            sealers:        sealers_in(rest),
            # Every command, not `rest` — the creating command carries the parent
            # link, which is the most common reference of all.
            references:     references_in(aggregate.commands),
            # Read from the language, not restated: a hand-written join here
            # could disagree with the runtime's own by even one separator.
            identity_paths: aggregate.identity_paths,
            entity_owned:   entity_owned
          )
        end

        # Which arguments of which verbs carry an ID, read straight off the IR.
        def references_in(commands)
          commands.each_with_object({}) do |command, found|
            named = command.attributes.select(&:reference?).map { |attribute| attribute.name.to_s }
            found[command.hecks_name] = named unless named.empty?
          end
        end

        # `owner_id` is excluded: it's traversal context, not stored identity state.
        def declaration_command(aggregate)
          required = aggregate.identity_heads.map(&:to_sym) - [:owner_id]
          candidates = aggregate.commands.select do |command|
            targets = Array(command.mutations).map { |mutation| mutation.target.to_sym }
            required.all? { |field| targets.include?(field) }
          end

          return candidates.first if candidates.one?

          raise DSL::Malformed,
                "#{aggregate.hecks_name} must declare exactly one command that establishes " \
                "its identity fields #{required.join(", ")} — found #{candidates.map(&:hecks_name).join(", ")}"
        end

        # The first declared reference attribute is the traversal parent.
        def parent_relationship_of(aggregate)
          aggregate.attributes.find(&:reference?)
        end

        # Every reference argument is dropped, not just the parent link:
        # a reference is not a field.
        def declared_fields(declare)
          return [] unless declare

          declare.attributes.reject(&:reference?).map { |attribute| attribute.name.to_s }
        end

        # list attribute -> the command that appends to it, and how its arguments map.
        def appends_in(commands)
          commands.each_with_object({}) do |command, found|
            Array(command.mutations).each do |mutation|
              next unless mutation.op == :append

              # First wins, not last: Aggregate.Attribute and Aggregate.Reference
              # both extend `attributes`; overwriting would displace one silently.
              found[mutation.target.to_s] ||= Append.new(verb: command.hecks_name, map: mutation.source)
            end
          end
        end

        # The appenders displaced by first-wins in `appends_in`; still verbs
        # the coverage gate must see.
        def alternates_in(commands)
          claimed = {}
          commands.flat_map do |command|
            Array(command.mutations).filter_map do |mutation|
              next unless mutation.op == :append

              target = mutation.target.to_s
              if claimed[target]
                Append.new(verb: command.hecks_name, map: mutation.source)
              else
                claimed[target] = true
                nil
              end
            end
          end
        end

        # Commands that set rather than append. Lifecycle sets two targets at once,
        # so a setter is keyed by its verb and carries every target it writes.
        def setters_in(commands)
          commands.filter_map do |command|
            targets = Array(command.mutations)
                      .select { |mutation| mutation.op == :set }
                      .to_h { |mutation| [mutation.target.to_s, mutation.source.to_s] }
            next if targets.empty?

            Setter.new(verb: command.hecks_name, targets: targets)
          end
        end

        # Commands that change nothing — they exist only to be refused.
        def sealers_in(commands)
          commands.select { |command| Array(command.mutations).empty? }.map(&:hecks_name)
        end
      end
    end
  end
end
