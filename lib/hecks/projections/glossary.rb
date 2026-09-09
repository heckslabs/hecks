require_relative "../projector"

module Hecks
  module Projections
    # A CHAPTER, PROJECTED AS ITS UBIQUITOUS LANGUAGE — one alphabetized
    # glossary entry per term the business actually uses: every Aggregate,
    # Entity, Value Object, Command (a verb), Query (a question), Read
    # Model, Event, Role, and Saga a bluebook declares.
    #
    # THE POINT OF THIS PROJECTION, and why it is not just `DocsProjector`
    # re-sorted. Evans' Ubiquitous Language is a glossary the DOMAIN
    # EXPERT reads and corrects — one alphabetical list, one sentence per
    # term, no aggregate structure to navigate first. `DocsProjector`
    # answers "how do I call this domain" (walked aggregate by aggregate,
    # verbs and refusals and wire shapes); this answers "what does this
    # domain mean" (walked term by term, in the order a dictionary is).
    # Same source, two different readers.
    #
    # WHAT IT DELIBERATELY DOES NOT DO: invent, same discipline as
    # `DocsProjector`. A term with no declared prose (most value objects;
    # every event and role, which the language only ever spells as bare
    # strings — a command's `emits:`/`role:`) gets a definition DERIVED
    # from the graph around it — what it's shaped like, what emits it,
    # who issues it — never a restated name standing in for a sentence
    # nobody wrote.
    #
    #   Projector.call(:glossary, bluebook: <the Bluebook chapter>)
    module Glossary
      extend Projector::Target

      projects_as :glossary

      Entry = Struct.new(:term, :kind, :definition, :within, keyword_init: true)

      module_function

      def call(bluebook:, options: {}) = render(bluebook)

      # ── gathering ─────────────────────────────────────────────────────

      # AN ENTITY CAN CARRY ITS OWN COMMANDS, QUERIES, AND VALUE OBJECTS
      # TOO — walked the same one level down `DocsProjector` and
      # `Projections::Diagrams` already walk it, so a domain's entity
      # gaining any of these needs no change here either.
      def holders(bluebook)
        bluebook.aggregates.flat_map { |aggregate| [aggregate, *aggregate.entities] }
      end

      def entries(bluebook)
        entries = []
        entries += aggregate_entries(bluebook)
        entries += entity_entries(bluebook)
        entries += value_object_entries(bluebook)
        entries += command_entries(bluebook)
        entries += query_entries(bluebook)
        entries += read_model_entries(bluebook)
        entries += event_entries(bluebook)
        entries += role_entries(bluebook)
        entries += saga_entries(bluebook)
        entries.sort_by { |entry| [entry.term.downcase, entry.kind] }
      end

      def aggregate_entries(bluebook)
        bluebook.aggregates.map do |aggregate|
          Entry.new(term: aggregate.hecks_name, kind: "Aggregate", definition: aggregate.description)
        end
      end

      def entity_entries(bluebook)
        bluebook.aggregates.flat_map do |aggregate|
          aggregate.entities.map do |entity|
            Entry.new(term: entity.hecks_name, kind: "Entity", within: aggregate.hecks_name,
                      definition: entity.description)
          end
        end
      end

      # A VALUE OBJECT CARRIES NO `description` — the language never gave
      # it one (`Bluebook::ValueObject` declares `attributes`,
      # `invariants`, `members`, `closed_set`, nothing else). Its
      # definition is derived from its own shape instead: a closed set
      # states its members, an open one its fields — the same
      # distinction `DocsProjector#shape_of` draws.
      #
      # AGGREGATES ONLY, not `holders` — unlike commands and queries, an
      # entity declares no value objects of its own (`Bluebook::Entity`
      # deliberately does not answer `value_objects`; its argument types
      # live on the aggregate above it, same as `DocsProjector#value_object_for`
      # already has to account for).
      def value_object_entries(bluebook)
        bluebook.aggregates.flat_map do |aggregate|
          aggregate.value_objects.map do |vo|
            Entry.new(term: vo.hecks_name, kind: "Value Object", within: aggregate.hecks_name,
                      definition: value_object_shape(vo))
          end
        end
      end

      # A CLOSED SET'S ROWS, not just their first field — the same
      # correction `Projections::Vocabulary` already had to make
      # (`StatementFrequency` names retention months and a paper fee
      # alongside its cadence; flattening every field into one list
      # produces well-formed nonsense, same as it did there).
      def value_object_shape(value_object)
        if value_object.closed_set?
          if value_object.members.first && value_object.members.first.size > 1
            rows = value_object.members.map { |row| "{ #{row.map { |f, v| "#{f}: #{v.inspect}" }.join(', ')} }" }
            "One of: #{rows.join('; ')}."
          else
            "One of #{value_object.members.flat_map(&:values).uniq.map { |m| "`#{m}`" }.join(', ')}."
          end
        elsif value_object.attributes.empty?
          "A marker with no fields of its own."
        else
          "{ #{value_object.attributes.map { |f| "#{f.name}: #{f.type}" }.join(', ')} }"
        end
      end

      def command_entries(bluebook)
        holders(bluebook).flat_map do |holder|
          holder.commands.map do |command|
            Entry.new(term: command.hecks_name, kind: "Command", within: holder.hecks_name,
                      definition: command.goal)
          end
        end
      end

      def query_entries(bluebook)
        holders(bluebook).flat_map do |holder|
          holder.queries.map do |query|
            Entry.new(term: query.hecks_name, kind: "Query", within: holder.hecks_name,
                      definition: query.description)
          end
        end
      end

      def read_model_entries(bluebook)
        bluebook.read_models.map do |read_model|
          Entry.new(term: read_model.name, kind: "Read Model", definition: read_model.description)
        end
      end

      # AN EVENT IS NEVER ITS OWN DECLARATION — the language only ever
      # spells one as a bare string in a command's `emits:`. So it earns
      # a glossary entry by appearing there, and its "definition" is the
      # one fact the graph actually holds about it: which verb(s) raise
      # it. That is derived, not invented — nobody wrote a sentence this
      # restates.
      def event_entries(bluebook)
        by_event = Hash.new { |h, k| h[k] = [] }
        holders(bluebook).each do |holder|
          holder.commands.each do |command|
            command.emits.each { |event| by_event[event] << command.hecks_name }
          end
        end
        by_event.map do |event, commands|
          Entry.new(term: event, kind: "Event",
                    definition: "Raised by #{commands.uniq.map { |c| "`#{c}`" }.join(', ')}.")
        end
      end

      # A ROLE IS THE SAME SHAPE OF FACT AS AN EVENT — free text on a
      # command's `role:`, never declared on its own — so it gets the
      # same treatment: who it is, told by what it does.
      def role_entries(bluebook)
        by_role = Hash.new { |h, k| h[k] = [] }
        holders(bluebook).each do |holder|
          holder.commands.select(&:role).each { |command| by_role[command.role] << command.hecks_name }
        end
        by_role.map do |role, commands|
          Entry.new(term: role, kind: "Role",
                    definition: "Issues #{commands.uniq.map { |c| "`#{c}`" }.join(', ')}.")
        end
      end

      def saga_entries(bluebook)
        bluebook.process_managers.map do |saga|
          shape = saga.to_h
          Entry.new(term: shape[:name], kind: "Saga",
                    definition: "Starts on `#{shape[:starts_on]}`, ends on `#{shape[:ends_on]}`.")
        end
      end

      # ── rendering ─────────────────────────────────────────────────────

      def render(bluebook)
        rows   = entries(bluebook).map { |entry| entry_row(entry) }
        vision = bluebook.vision ? "> #{bluebook.vision}\n\n" : ""

        <<~MARKDOWN
          # #{bluebook.name} — Glossary

          #{vision}The ubiquitous language: every term #{bluebook.name} declares, alphabetized, in the domain's own words. Generated from `#{bluebook.name}`'s bluebook — a term missing here is a term the bluebook does not yet declare, and a definition missing here is a sentence nobody has written yet.

          | Term | Kind | Definition |
          |---|---|---|
          #{rows.join("\n")}
        MARKDOWN
      end

      def entry_row(entry)
        term = entry.within ? "**#{entry.term}** *(#{entry.within})*" : "**#{entry.term}**"
        "| #{term} | #{entry.kind} | #{entry.definition || '—'} |"
      end
    end
  end
end
