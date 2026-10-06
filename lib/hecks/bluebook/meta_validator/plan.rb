require_relative "plan/category"
require_relative "plan/verbs"

module Hecks
  module Bluebook
    module MetaValidator
      # The language's own self-description, read back as a walkable structure:
      # which command appends to which list, and how the containment tree nests.
      class Plan
        include Verbs

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
          declare = entity_owned ? nil : declaration_command(aggregate)
          rest    = aggregate.commands - [declare].compact

          Category.new(**placement(aggregate, declare, owner), **verbs_in(aggregate, declare, rest),
                       entity_owned: entity_owned)
        end

        # Where the category sits in the containment tree and how it is identified.
        def placement(aggregate, declare, owner)
          parent = parent_relationship_of(aggregate)

          {
            name:           aggregate.hecks_name,
            declare:        declare&.hecks_name,
            parent:         owner || parent&.type&.target_name,
            parent_key:     owner ? "aggregate" : parent&.name&.to_s,
            # Read from the language, not restated: a hand-written join here
            # could disagree with the runtime's own by even one separator.
            identity_paths: aggregate.identity_paths
          }
        end

        # The commands the category declares, sorted by what they do to it.
        def verbs_in(aggregate, declare, rest)
          {
            fields:     declared_fields(declare),
            appends:    appends_in(rest),
            alternates: alternates_in(rest),
            setters:    setters_in(rest),
            sealers:    sealers_in(rest),
            # Every command, not `rest` — the creating command carries the parent
            # link, which is the most common reference of all.
            references: references_in(aggregate.commands)
          }
        end

        # `owner_id` is excluded: it's traversal context, not stored identity state.
        def declaration_command(aggregate)
          required = aggregate.identity_heads.map(&:to_sym) - [:owner_id]
          candidates = aggregate.commands.select { |command| establishes?(command, required) }

          return candidates.first if candidates.one?

          raise DSL::Malformed,
                "#{aggregate.hecks_name} must declare exactly one command that establishes " \
                "its identity fields #{required.join(", ")} — found #{candidates.map(&:hecks_name).join(", ")}"
        end

        # Whether `command` writes every one of the `fields`.
        def establishes?(command, fields)
          targets = Array(command.mutations).map { |mutation| mutation.target.to_sym }
          fields.all? { |field| targets.include?(field) }
        end

        # The first declared reference attribute is the traversal parent.
        def parent_relationship_of(aggregate)
          aggregate.attributes.find(&:reference?)
        end
      end
    end
  end
end
