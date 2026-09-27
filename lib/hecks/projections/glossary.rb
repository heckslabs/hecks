require_relative "../projector"
require_relative "../naming"
require_relative "statements"
require_relative "glossary/sections"
require_relative "glossary/sensitivity"
require_relative "glossary/sentences"
require_relative "glossary/mermaid"
require_relative "glossary/markdown"
require_relative "glossary/html"

module Hecks
  module Projections
    # A chapter projected as a plain-language glossary, grouped by aggregate,
    # as `glossary.md` plus an HTML page rendered from that same Markdown.
    #
    #   Projector.call(:glossary, bluebook: chapter)
    #   # => { "glossary.md" => "...", "html/index.html" => "..." }
    module Glossary
      extend Projector::Target

      projects_as :glossary, emits: :files

      # One term. `headword` and `slug` are assigned once the document's order is known.
      Entry = Struct.new(:name, :kind, :within, :section, :facts, :headword, :slug, keyword_init: true)

      Section = Struct.new(:name, :title, :aggregate, :terms, :slug, keyword_init: true)

      Document = Struct.new(:bluebook, :sections, :index, :markings, keyword_init: true)

      module_function

      # Projects `bluebook`'s glossary as a Markdown document and the HTML page built from it.
      #
      # @param bluebook [Bluebook::Behaviour::Chapter] the chapter to render
      # @param options [Hash] the registry's call shape
      # @option options [Array<Hash{Symbol => String}>] :markings sensitive fields to tag
      #   with their category and list under their aggregate
      # @return [Hash{String => String}] `"glossary.md"` and `"html/index.html"`
      def call(bluebook:, options: {})
        markdown = Markdown.render(document(bluebook, Array(options[:markings])))
        { "glossary.md" => markdown, "html/index.html" => Html.render(markdown) }
      end

      # Gathers every term, groups it into sections, assigns headings and
      # slugs, and builds the index links resolve through.
      def document(bluebook, markings = [])
        sections = sections(bluebook, entries(bluebook, markings))
        Slugs.assign!(bluebook, sections)
        Document.new(bluebook: bluebook, sections: sections, index: Index.new(sections), markings: markings)
      end

      # Aggregates first, A to Z by spoken name, then the groups no aggregate homes.
      def sections(bluebook, entries)
        grouped = entries.group_by(&:section)
        list = bluebook.aggregates.sort_by { |aggregate| Naming.words(aggregate.hecks_name).downcase }.map do |aggregate|
          Section.new(name: aggregate.hecks_name, title: Naming.words(aggregate.hecks_name), aggregate: aggregate,
                      terms: with_headwords(grouped.fetch(aggregate.hecks_name, []), aggregate.hecks_name))
        end
        [ROLES, READ_MODELS, REACTIONS].each do |name|
          held = grouped[name == REACTIONS ? nil : name]
          list << Section.new(name: name, title: name, terms: with_headwords(held, name)) if held
        end
        list
      end

      # A headword is qualified only when it would repeat within its section, never numbered.
      def with_headwords(entries, section_name)
        entries.each { |entry| entry.headword = Naming.words(entry.name) }
        entries.group_by(&:headword).each_value do |group|
          next if group.size == 1

          group.each { |entry| entry.headword = qualified(entry, group, section_name) }
        end
        entries.sort_by { |entry| [entry.headword.downcase, entry.kind.to_s] }
      end

      def qualified(entry, group, section_name)
        base = Naming.words(entry.name)
        return "#{base} (the list)" if entry.kind == :query && group.any? { |other| other.kind == :command }
        return "#{base} (#{Naming.words(entry.within).downcase})" if entry.within && entry.within != section_name

        base
      end

      # Entities carry their own commands and queries, so they are walked one level down.
      def holders(bluebook)
        bluebook.aggregates.flat_map { |aggregate| [aggregate, *aggregate.entities] }
      end

      # Maps every holder name to its owning aggregate's name.
      def holder_aggregate(bluebook)
        bluebook.aggregates.each_with_object({}) do |aggregate, map|
          map[aggregate.hecks_name] = aggregate.hecks_name
          aggregate.entities.each { |entity| map[entity.hecks_name] = aggregate.hecks_name }
        end
      end

      # Maps each emitted event to its `[holder, command]` raisers. An event is never
      # declared, so its home is the first raiser's aggregate.
      def event_raisers(bluebook)
        holders(bluebook).each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |holder, map|
          holder.commands.each { |command| command.emits.each { |event| map[event] << [holder, command] } }
        end
      end

      # The last segment of a dotted name.
      def bare(qualified) = qualified.to_s.split(".").last

      # Gathers every term the glossary carries, ungrouped and unordered.
      def entries(bluebook, markings = [])
        homes   = holder_aggregate(bluebook)
        raisers = event_raisers(bluebook)
        home_of = ->(event) { raisers.key?(event) ? homes[raisers[event].first.first.hecks_name] : nil }

        entries = []
        entries += entity_entries(bluebook)
        entries += value_object_entries(bluebook, markings)
        entries += verb_entries(bluebook, homes)
        entries += event_entries(bluebook, raisers, home_of)
        entries += policy_entries(bluebook, home_of)
        entries += saga_entries(bluebook, home_of)
        entries += role_entries(bluebook)
        entries += read_model_entries(bluebook)
        entries
      end

      def entity_entries(bluebook)
        bluebook.aggregates.flat_map do |aggregate|
          aggregate.entities.map do |entity|
            Entry.new(name: entity.hecks_name, kind: :entity, within: aggregate.hecks_name,
                      section: aggregate.hecks_name, facts: { entity: entity })
          end
        end
      end

      # Aggregates only; `Bluebook::Entity` deliberately does not answer `value_objects`.
      def value_object_entries(bluebook, markings = [])
        bluebook.aggregates.flat_map do |aggregate|
          marked = Sensitivity.for_aggregate(markings, bluebook.name, aggregate)
          aggregate.value_objects.map do |value_object|
            sensitive = Sensitivity.for_value_object(marked, aggregate, value_object)
            Entry.new(name: value_object.hecks_name, kind: :value_object, within: aggregate.hecks_name,
                      section: aggregate.hecks_name,
                      facts: { value_object: value_object, sensitive: sensitive })
          end
        end
      end

      def verb_entries(bluebook, homes)
        holders(bluebook).flat_map do |holder|
          commands = holder.commands.map do |command|
            Entry.new(name: command.hecks_name, kind: :command, within: holder.hecks_name,
                      section: homes[holder.hecks_name], facts: { command: command, holder: holder })
          end
          queries = holder.queries.map do |query|
            Entry.new(name: query.hecks_name, kind: :query, within: holder.hecks_name,
                      section: homes[holder.hecks_name], facts: { query: query })
          end
          commands + queries
        end
      end

      def event_entries(bluebook, raisers, home_of)
        raisers.map do |event, raised_by|
          reactions = bluebook.policies.select { |policy| bare(policy.on_event) == event }
          Entry.new(name: event, kind: :event, section: home_of.call(event),
                    facts: { event: event, raised_by: raised_by, policies: reactions })
        end
      end

      def policy_entries(bluebook, home_of)
        bluebook.policies.map do |policy|
          Entry.new(name: policy.name, kind: :policy, section: home_of.call(bare(policy.on_event)),
                    facts: { policy: policy })
        end
      end

      def saga_entries(bluebook, home_of)
        bluebook.process_managers.map do |saga|
          shape = saga.to_h
          Entry.new(name: shape[:name], kind: :saga, section: home_of.call(bare(shape[:starts_on])),
                    facts: { saga: shape })
        end
      end

      # Roles cut across aggregates, so they get their own section.
      def role_entries(bluebook)
        by_role = Hash.new { |hash, key| hash[key] = [] }
        holders(bluebook).each do |holder|
          holder.commands.select(&:role).each { |command| by_role[command.role] << [holder, command] }
        end
        by_role.map do |role, issues|
          Entry.new(name: role, kind: :role, section: ROLES, facts: { role: role, commands: issues })
        end
      end

      # A read model joins heads from more than one aggregate, so it belongs to none.
      def read_model_entries(bluebook)
        bluebook.read_models.map do |read_model|
          Entry.new(name: read_model.name, kind: :read_model, section: READ_MODELS, facts: { read_model: read_model })
        end
      end

      # Reproduces GitHub's heading slugs, computed in document order, so links land the
      # same whether GitHub renders the `.md` or `Html` renders the page.
      module Slugs
        module_function

        def github(text) = text.to_s.downcase.gsub(/[^\p{Word}\- ]/, "").tr(" ", "-")

        # Assigns every section's and entry's slug, in document order.
        def assign!(bluebook, sections)
          seen = Hash.new(0)
          take = lambda do |text|
            base = github(text)
            seen[base] += 1
            seen[base] == 1 ? base : "#{base}-#{seen[base] - 1}"
          end
          take.call(Markdown.title(bluebook))
          sections.each do |section|
            section.slug = take.call(section.title)
            section.terms.each { |entry| entry.slug = take.call(entry.headword) }
          end
        end
      end

      # Resolves declared references structurally, never by searching prose. An
      # undeclared target (a cross-domain command) answers nil and renders unlinked.
      class Index
        def initialize(sections)
          @by_key = {}
          sections.each do |section|
            @by_key[[:aggregate, section.name]] = section if section.aggregate
            section.terms.each { |entry| @by_key[key_of(entry)] = entry }
          end
        end

        # Commands, queries and value objects can share a bare name across holders, so
        # their key includes the holder.
        def key_of(entry)
          case entry.kind
          when :command, :query, :value_object then [entry.kind, entry.within, entry.name]
          else [entry.kind, entry.name]
          end
        end

        # @return [Entry, Section, nil] the matching term or aggregate section
        def [](kind, name, within: nil)
          @by_key[within ? [kind, within, name] : [kind, name]]
        end

        # A Markdown link to a term's heading, or the plain words when undeclared.
        # `label:` overrides the link text to tell two same-named terms apart.
        def link(kind, name, within: nil, label: nil)
          target = self[kind, name, within: within]
          return label || Naming.words(name) unless target

          text = label || (target.is_a?(Section) ? target.title : target.headword)
          "[#{text}](##{target.slug})"
        end
      end
    end
  end
end
