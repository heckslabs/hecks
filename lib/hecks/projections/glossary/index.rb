require_relative "../../naming"

module Hecks
  module Projections
    module Glossary
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

        # Looks up a term or aggregate section by kind and name.
        #
        # @return [Entry, Section, nil]
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
