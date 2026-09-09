require_relative "sections"
require_relative "sentences"
require_relative "mermaid"
require_relative "../statements"

module Hecks
  module Projections
    module Glossary
      # THE DOCUMENT ITSELF — `glossary.md`, the one source the page is
      # rendered from. Written in the handful of Markdown constructs
      # GitHub renders as-is (headings, blockquotes, ```mermaid fences,
      # lists, in-page links), so the file is a complete, readable
      # glossary on its own before any page is built from it:
      #
      #   # Banking — Glossary
      #   > vision
      #   lede
      #   ```mermaid          the map
      #   ## Account
      #   > description
      #   Starts out open. Can be open, frozen, or closed.
      #   **How it fits**     ```mermaid
      #   **How it moves**    ```mermaid
      #   **Always true**     - one sentence per declared fact
      #   ### Account number  one ### per term, A to Z
      #   Made up of a value (text).
      #   Always true: an account number is present.
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

        def title(bluebook) = "#{bluebook.name} — Glossary"

        def render(document)
          parts = [header(document.bluebook)]
          parts += document.sections.map { |section| section_text(section, document) }
          "#{parts.join("\n\n")}\n"
        end

        def header(bluebook)
          parts = ["# #{title(bluebook)}"]
          parts << "> #{bluebook.vision}" if bluebook.vision
          parts << format(LEDE, name: bluebook.name)
          parts << fence(Mermaid.map(bluebook))
          parts.join("\n\n")
        end

        def section_text(section, document)
          parts = ["## #{section.title}"]
          parts += section.aggregate ? opening(section.aggregate, document.bluebook) : ["> #{STANDING[section.name]}"]
          parts += section.terms.map { |entry| term_text(entry, document.index) }
          parts.join("\n\n")
        end

        # What an aggregate IS, what it can be, how it fits and moves,
        # and what is always true of it — before a single term.
        def opening(aggregate, bluebook)
          parts = []
          parts << "> #{aggregate.description}" if aggregate.description
          parts << Sentences.lifecycle_sentence(aggregate.lifecycle) if aggregate.lifecycle
          parts << "**How it fits**" << fence(Mermaid.context(aggregate, bluebook))
          parts << "**How it moves**" << fence(Mermaid.lifecycle(aggregate)) if aggregate.lifecycle
          statements = always_true(aggregate, bluebook)
          parts << "**Always true**" << statements.map { |statement| "- #{statement}" }.join("\n") unless statements.empty?
          parts
        end

        # THE STATEMENTS PROJECTION'S OWN SENTENCES, SPOKEN. An invariant
        # is the author's words and stays exactly so. A relationship
        # sentence is built mechanically from construct names ("An
        # ATMCard references an Account."), and a construct name is the
        # one thing this page never shows as an identifier — so each is
        # replaced with how it is said, whole-word, and nothing else in
        # the sentence is touched.
        def always_true(aggregate, bluebook)
          names = bluebook.aggregates.flat_map { |other| [other.hecks_name, *other.entities.map(&:hecks_name)] }
          [aggregate, *aggregate.entities].flat_map do |holder|
            Statements.attribute_statements(holder).map { |sentence| spoken(sentence, names) } +
              Statements.invariant_statements(holder)
          end.uniq
        end

        def spoken(sentence, names)
          names.reduce(sentence) { |text, name| text.gsub(/\b#{Regexp.escape(name)}\b/, Naming.words(name)) }
        end

        def term_text(entry, index)
          ["### #{entry.headword}", *Sentences.paragraphs(entry, index)].join("\n\n")
        end

        def fence(source) = "```mermaid\n#{source}\n```"
      end
    end
  end
end
