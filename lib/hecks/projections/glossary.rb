require_relative "../projector"
require_relative "../naming"
require_relative "statements"
require_relative "glossary/sections"
require_relative "glossary/sensitivity"
require_relative "glossary/sentences"
require_relative "glossary/mermaid"
require_relative "glossary/markdown"
require_relative "glossary/html"
require_relative "glossary/entries"
require_relative "glossary/slugs"
require_relative "glossary/index"

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
        sections = sections(bluebook, Entries.all(bluebook, markings))
        Slugs.assign!(bluebook, sections)
        Document.new(bluebook: bluebook, sections: sections, index: Index.new(sections), markings: markings)
      end

      # Aggregates first, A to Z by spoken name, then the groups no aggregate homes.
      def sections(bluebook, entries)
        grouped = entries.group_by(&:section)
        aggregate_sections(bluebook, grouped) + group_sections(grouped)
      end

      def aggregate_sections(bluebook, grouped)
        bluebook.aggregates.sort_by { |aggregate| Naming.words(aggregate.hecks_name).downcase }.map do |aggregate|
          Section.new(name: aggregate.hecks_name, title: Naming.words(aggregate.hecks_name), aggregate: aggregate,
                      terms: with_headwords(grouped.fetch(aggregate.hecks_name, []), aggregate.hecks_name))
        end
      end

      # The sections no aggregate homes: roles, read models and reactions, when any term belongs.
      def group_sections(grouped)
        [ROLES, READ_MODELS, REACTIONS].filter_map do |name|
          held = grouped[name == REACTIONS ? nil : name]
          Section.new(name: name, title: name, terms: with_headwords(held, name)) if held
        end
      end

      # A headword is qualified only when it would repeat within its section, never numbered.
      def with_headwords(entries, section_name)
        entries.each { |entry| entry.headword = Naming.words(entry.name) }
        entries.group_by(&:headword).each_value { |group| qualify_repeats(group, section_name) }
        entries.sort_by { |entry| [entry.headword.downcase, entry.kind.to_s] }
      end

      def qualify_repeats(group, section_name)
        return if group.size == 1

        group.each { |entry| entry.headword = qualified(entry, group, section_name) }
      end

      def qualified(entry, group, section_name)
        base = Naming.words(entry.name)
        return "#{base} (the list)" if entry.kind == :query && group.any? { |other| other.kind == :command }
        return "#{base} (#{Naming.words(entry.within).downcase})" if entry.within && entry.within != section_name

        base
      end
    end
  end
end
