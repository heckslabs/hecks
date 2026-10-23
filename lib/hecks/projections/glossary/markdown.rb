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
        LEDE = "The terms %<name>s uses, written the way the people who work in it would say them. " \
               "Each term sits under the thing it belongs to: first what can be done with it, then " \
               "what it records, the lists you can ask for, and what it is made of. The page is " \
               "generated from the working specification, so it describes what the system does today. " \
               "If a sentence reads wrong to you, the specification is wrong, and it is worth saying so.".freeze

        STANDING = {
          ROLES       => "Who does what. Each role is listed once, with the actions it is responsible for.",
          READ_MODELS => "Questions answered by reading more than one of the things above.",
          REACTIONS   => "What happens on its own when something arrives from outside this specification."
        }.freeze

        module_function

        # Titles the document after its chapter.
        def title(bluebook) = "#{bluebook.name} glossary"

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
          parts << fence(Mermaid.map(bluebook)) if bluebook.aggregates.size > 1
          parts.join("\n\n")
        end

        # Renders one `##` section: its opening, then every term inside it.
        def section_text(section, document)
          terms = Groups.walk(section).map do |kind, item|
            kind == :group ? "### #{item}" : term_text(item, document.index)
          end
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

        # The "How it fits" diagram when the aggregate has neighbours to draw, and "How it moves"
        # with each move in words when it has a lifecycle.
        def diagrams(aggregate, bluebook)
          parts = []
          parts << "**How it fits**" << fence(Mermaid.context(aggregate, bluebook)) if Mermaid.neighbours?(aggregate, bluebook)
          parts + moves(aggregate)
        end

        def moves(aggregate)
          return [] unless aggregate.lifecycle

          lines = Statements::Actions.lifecycle(aggregate).drop(1).map { |sentence| "- #{sentence}" }
          ["**How it moves**", fence(Mermaid.lifecycle(aggregate)), lines.join("\n")]
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

        # The statements projection's relationship and invariant sentences for `aggregate` and
        # its entities, each said once.
        def always_true(aggregate, _bluebook)
          [aggregate, *aggregate.entities].flat_map do |holder|
            Statements.attribute_statements(holder) + Statements.invariant_statements(holder)
          end.uniq
        end

        # Renders one term's `####` heading and its paragraphs.
        def term_text(entry, index)
          ["#### #{entry.headword}", *Sentences.paragraphs(entry, index)].join("\n\n")
        end

        # Wraps a Mermaid diagram's source in a fenced code block.
        def fence(source) = "```mermaid\n#{source}\n```"
      end
    end
  end
end
