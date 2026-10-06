require_relative "sections"
require_relative "sensitivity"
require_relative "sentences"
require_relative "mermaid"
require_relative "../statements"

module Hecks
  module Projections
    module Glossary
      # Renders `glossary.md`, the source the glossary page is built from.
      # Uses only Markdown that GitHub renders as-is, so the file reads on its own.
      module Markdown
        LEDE = "Every term %<name>s uses, in the words of the people who work in it — grouped under the thing " \
               "each belongs to, and listed A to Z within it. This page is generated from the working " \
               "specification, so it says what the system does today, not what anyone hoped it would do. " \
               "If a sentence here reads wrong to you, the specification is wrong: say so.".freeze

        STANDING = {
          ROLES       => "Who does what. A role is named once here rather than under every term it touches.",
          READ_MODELS => "Questions answered across more than one of the things above.",
          REACTIONS   => "What happens on its own, in response to something this specification does not itself raise."
        }.freeze

        module_function

        # Titles the document after its chapter.
        def title(bluebook) = "#{bluebook.name} — Glossary"

        # Renders the full `glossary.md` document.
        #
        # @param document [Glossary::Document] the assembled document to render
        # @return [String] the complete Markdown source, ending in a newline
        def render(document)
          parts = [header(document.bluebook)]
          parts += document.sections.map { |section| section_text(section, document) }
          "#{parts.join("\n\n")}\n"
        end

        # Renders the title, vision blockquote, lede, and overview map.
        def header(bluebook)
          parts = ["# #{title(bluebook)}"]
          parts << "> #{bluebook.vision}" if bluebook.vision
          parts << format(LEDE, name: bluebook.name)
          parts << fence(Mermaid.map(bluebook))
          parts.join("\n\n")
        end

        # Renders one `##` section: its opening, then every term inside it.
        def section_text(section, document)
          terms = section.terms.map { |entry| term_text(entry, document.index) }
          ["## #{section.title}", *section_opening(section, document), *terms].join("\n\n")
        end

        # The paragraphs that open a section: an aggregate's own, or the standing note of a group.
        def section_opening(section, document)
          return ["> #{STANDING[section.name]}"] unless section.aggregate

          marked = Sensitivity.for_aggregate(document.markings, document.bluebook.name, section.aggregate)
          opening(section.aggregate, document.bluebook, marked)
        end

        # An aggregate's opening: what it is, how it fits and moves, what is always true.
        def opening(aggregate, bluebook, marked = [])
          parts = []
          parts << "> #{aggregate.description}" if aggregate.description
          parts << Sentences.lifecycle_sentence(aggregate.lifecycle) if aggregate.lifecycle
          parts + diagrams(aggregate, bluebook) + facts(always_true(aggregate, bluebook), marked)
        end

        # The "How it fits" diagram, and "How it moves" when the aggregate has a lifecycle.
        def diagrams(aggregate, bluebook)
          parts = ["**How it fits**", fence(Mermaid.context(aggregate, bluebook))]
          parts << "**How it moves**" << fence(Mermaid.lifecycle(aggregate)) if aggregate.lifecycle
          parts
        end

        # The "Always true" and "Handled as sensitive" lists, each only when it has lines.
        def facts(statements, marked)
          parts = []
          parts << "**Always true**" << statements.map { |statement| "- #{statement}" }.join("\n") unless statements.empty?
          unless marked.empty?
            lines = marked.map { |marking| "- #{Sensitivity.sentence(marking)}" }
            parts << "**Handled as sensitive**" << lines.join("\n")
          end
          parts
        end

        # The statements projection's sentences for `aggregate` and its entities, spoken.
        # Invariants stay verbatim; construct names in other sentences are replaced with
        # how they are said, because this page never shows an identifier.
        def always_true(aggregate, bluebook)
          names = bluebook.aggregates.flat_map { |other| [other.hecks_name, *other.entities.map(&:hecks_name)] }
          [aggregate, *aggregate.entities].flat_map do |holder|
            Statements.attribute_statements(holder).map { |sentence| spoken(sentence, names) } +
              Statements.invariant_statements(holder)
          end.uniq
        end

        # Replaces every whole-word construct name in `sentence` with how it is said.
        def spoken(sentence, names)
          names.reduce(sentence) { |text, name| text.gsub(/\b#{Regexp.escape(name)}\b/, Naming.words(name)) }
        end

        # Renders one term's `###` heading and its paragraphs.
        def term_text(entry, index)
          ["### #{entry.headword}", *Sentences.paragraphs(entry, index)].join("\n\n")
        end

        # Wraps a Mermaid diagram's source in a fenced code block.
        def fence(source) = "```mermaid\n#{source}\n```"
      end
    end
  end
end
