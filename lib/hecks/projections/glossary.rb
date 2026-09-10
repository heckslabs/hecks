require_relative "../projector"
require_relative "../naming"
require_relative "statements"
require_relative "glossary/sections"
require_relative "glossary/sentences"
require_relative "glossary/mermaid"
require_relative "glossary/markdown"
require_relative "glossary/html"

module Hecks
  module Projections
    # A CHAPTER, PROJECTED AS ITS UBIQUITOUS LANGUAGE — a glossary for the
    # whole team, in the sense Evans meant (DDD ch. 2): ONE language,
    # shared by domain experts and developers, written the same way in
    # conversation, diagrams, documents and code, so that a subject-matter
    # expert can read the model and say "yes, that's how it works" or
    # "no, that's wrong". A banker, a support rep, the CEO and an engineer
    # read the same page.
    #
    # THREE THINGS FOLLOW FROM THAT AUDIENCE. First, no type jargon: a
    # term is a term, not "an Aggregate" or "a Value Object", and every
    # identifier is spelled as a person says it (`Naming.words`: `ATMCard`
    # is "ATM card"). Second, nothing invented: every sentence is either
    # the domain author's own words (a `description`, a `goal`, an
    # invariant) or built mechanically from a declared fact ("Recorded
    # after Freeze account") — the same discipline `DocsProjector` holds
    # to; a wrong sentence is worse than a missing one. Third, grouped
    # under the aggregate each term belongs to, A to Z within it — a
    # reader thinks "what does Account mean" before "what starts with A",
    # and once there reads the way a dictionary reads.
    #
    # TWO FILES FROM ONE SOURCE. `glossary.md` is the document — every
    # construct in it renders on GitHub as-is (headings, blockquotes,
    # ```mermaid fences, lists, in-page links). `html/index.html` is that
    # exact Markdown string rendered into a page with a navigation rail;
    # it is built FROM the Markdown, not beside it, so the two cannot
    # drift. `bin/project_glossary` writes both to `<domain>/glossary/` beside
    # the bluebook (examples/banking, examples/pizzas, and the QA ledger in qa/).
    #
    #   Projector.call(:glossary, bluebook: <the Bluebook chapter>)
    #   # => { "glossary.md" => "...", "html/index.html" => "..." }
    module Glossary
      extend Projector::Target

      projects_as :glossary, emits: :files

      # One term. `kind` is a Symbol the renderers never print; `facts`
      # carries the declaration objects the sentence is built from;
      # `headword` and `slug` are assigned once the document's order is
      # known (a headword may need qualifying, a slug depends on what
      # came before it).
      Entry = Struct.new(:name, :kind, :within, :section, :facts, :headword, :slug, keyword_init: true)

      # One `##` of the document: an aggregate (with its own object, for
      # the lede and diagrams) or one of the three trailing groups.
      Section = Struct.new(:name, :title, :aggregate, :terms, :slug, keyword_init: true)

      Document = Struct.new(:bluebook, :sections, :index, keyword_init: true)

      module_function

      def call(bluebook:, options: {})
        markdown = Markdown.render(document(bluebook))
        { "glossary.md" => markdown, "html/index.html" => Html.render(markdown) }
      end

      # ── the document ─────────────────────────────────────────────────

      def document(bluebook)
        sections = sections(bluebook, entries(bluebook))
        Slugs.assign!(bluebook, sections)
        Document.new(bluebook: bluebook, sections: sections, index: Index.new(sections))
      end

      # AGGREGATES FIRST, A TO Z BY THEIR SPOKEN NAME ("Account" before
      # "ATM card"), then the three groups nothing homes to one aggregate.
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

      # A HEADWORD IS QUALIFIED ONLY WHEN IT WOULD REPEAT within its own
      # section — "Open" the action and "Open (the list)" the question;
      # "Return (key issuance)" beside another Return — never numbered
      # (Chicago 18.9, MDN's disambiguation pages: qualify the headword).
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

      # ── gathering ────────────────────────────────────────────────────

      # AN ENTITY CAN CARRY ITS OWN COMMANDS AND QUERIES TOO — walked the
      # same one level down `DocsProjector` and `Projections::Diagrams`
      # already walk it.
      def holders(bluebook)
        bluebook.aggregates.flat_map { |aggregate| [aggregate, *aggregate.entities] }
      end

      # EVERY HOLDER'S OWN AGGREGATE, ONE HOP OR ZERO — an aggregate maps
      # to itself, an entity to whichever aggregate declared it. The one
      # fact the grouping is built on.
      def holder_aggregate(bluebook)
        bluebook.aggregates.each_with_object({}) do |aggregate, map|
          map[aggregate.hecks_name] = aggregate.hecks_name
          aggregate.entities.each { |entity| map[entity.hecks_name] = aggregate.hecks_name }
        end
      end

      # EVERY EVENT'S RAISERS — an event is never declared, only emitted,
      # so its home is whichever aggregate the FIRST command that raises
      # it belongs to; a policy or saga reacting to it inherits that home.
      def event_raisers(bluebook)
        holders(bluebook).each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |holder, map|
          holder.commands.each { |command| command.emits.each { |event| map[event] << [holder, command] } }
        end
      end

      def bare(qualified) = qualified.to_s.split(".").last

      def entries(bluebook)
        homes   = holder_aggregate(bluebook)
        raisers = event_raisers(bluebook)
        home_of = ->(event) { raisers.key?(event) ? homes[raisers[event].first.first.hecks_name] : nil }

        entries = []
        entries += entity_entries(bluebook)
        entries += value_object_entries(bluebook)
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

      # AGGREGATES ONLY — an entity declares no value objects of its own
      # (`Bluebook::Entity` deliberately does not answer `value_objects`).
      def value_object_entries(bluebook)
        bluebook.aggregates.flat_map do |aggregate|
          aggregate.value_objects.map do |value_object|
            Entry.new(name: value_object.hecks_name, kind: :value_object, within: aggregate.hecks_name,
                      section: aggregate.hecks_name, facts: { value_object: value_object })
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

      # CROSS-CUTTING BY NATURE — `System` and `Customer` issue commands
      # across half the aggregates here — so a role belongs to no single
      # one and gets its own section.
      def role_entries(bluebook)
        by_role = Hash.new { |hash, key| hash[key] = [] }
        holders(bluebook).each do |holder|
          holder.commands.select(&:role).each { |command| by_role[command.role] << [holder, command] }
        end
        by_role.map do |role, issues|
          Entry.new(name: role, kind: :role, section: ROLES, facts: { role: role, commands: issues })
        end
      end

      # A read model joins heads from more than one aggregate — its own
      # header says so — so it belongs to none of them.
      def read_model_entries(bluebook)
        bluebook.read_models.map do |read_model|
          Entry.new(name: read_model.name, kind: :read_model, section: READ_MODELS, facts: { read_model: read_model })
        end
      end

      # ── anchors ──────────────────────────────────────────────────────

      # GITHUB'S OWN HEADING SLUGS, REPRODUCED — lowercase, punctuation
      # dropped, spaces to hyphens, a repeat gets "-1", "-2" in document
      # order. Computed here, once, in the order the headings will appear,
      # so a link written into the Markdown lands on the same heading
      # whether GitHub renders the `.md` or `Html` renders the page.
      module Slugs
        module_function

        def github(text) = text.to_s.downcase.gsub(/[^\p{Word}\- ]/, "").tr(" ", "-")

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

      # WHERE A DECLARED REFERENCE POINTS — keyed structurally (a command
      # by its holder AND name, an event by its bare name), never by
      # searching prose for a matching word. Anything not declared here
      # (a cross-domain command like `Notifications.Send`) answers nil,
      # and the sentence says it in words with no link.
      class Index
        def initialize(sections)
          @by_key = {}
          sections.each do |section|
            @by_key[[:aggregate, section.name]] = section if section.aggregate
            section.terms.each { |entry| @by_key[key_of(entry)] = entry }
          end
        end

        def key_of(entry)
          case entry.kind
          when :command, :query, :value_object then [entry.kind, entry.within, entry.name]
          else [entry.kind, entry.name]
          end
        end

        def [](kind, name, within: nil)
          @by_key[within ? [kind, within, name] : [kind, name]]
        end

        # A Markdown link to a term's own heading, or the plain words when
        # the chapter declares no such term. `label:` overrides the link
        # text for a sentence that has to tell two same-named terms apart.
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
