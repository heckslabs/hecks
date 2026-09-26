require_relative "sections"
require_relative "sensitivity"
require_relative "sentences"
require_relative "mermaid"
require_relative "../statements"

module Hecks
  module Projections
    module Glossary
      # **The document itself** — `glossary.md`, the one source the page is
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

        # Titles the document after its chapter.
        #
        # @param bluebook [Bluebook::Behaviour::Chapter] the chapter to title after
        # @return [String] the document's `#` heading text
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

        # Renders the document's title, vision blockquote, lede, and overview map.
        #
        # @param bluebook [Bluebook::Behaviour::Chapter] the chapter to render a
        #   header for
        # @return [String] the header's Markdown source
        def header(bluebook)
          parts = ["# #{title(bluebook)}"]
          parts << "> #{bluebook.vision}" if bluebook.vision
          parts << format(LEDE, name: bluebook.name)
          parts << fence(Mermaid.map(bluebook))
          parts.join("\n\n")
        end

        # Renders one `##` section: its opening (an aggregate's, or a standing
        # group's blurb), followed by every term inside it.
        #
        # @param section [Glossary::Section] the section to render
        # @param document [Glossary::Document] the document `section` belongs to,
        #   for its bluebook and link index
        # @return [String] the section's Markdown source
        def section_text(section, document)
          parts = ["## #{section.title}"]
          parts += if section.aggregate
                     marked = Sensitivity.for_aggregate(document.markings, document.bluebook.name, section.aggregate)
                     opening(section.aggregate, document.bluebook, marked)
                   else
                     ["> #{STANDING[section.name]}"]
                   end
          parts += section.terms.map { |entry| term_text(entry, document.index) }
          parts.join("\n\n")
        end

        # What an aggregate is, what it can be, how it fits and moves,
        # and what is always true of it — before a single term.
        #
        # @param aggregate [Bluebook::Aggregate] the aggregate to render an opening for
        # @param bluebook [Bluebook::Behaviour::Chapter] the chapter `aggregate` belongs
        #   to, for drawing its context diagram
        # @param marked [Array<Hash{Symbol => String}>] the markings that flag
        #   `aggregate`'s own fields sensitive, listed after its rules
        # @return [Array<String>] the opening's Markdown blocks, one per paragraph or
        #   diagram, not yet joined
        def opening(aggregate, bluebook, marked = [])
          parts = []
          parts << "> #{aggregate.description}" if aggregate.description
          parts << Sentences.lifecycle_sentence(aggregate.lifecycle) if aggregate.lifecycle
          parts << "**How it fits**" << fence(Mermaid.context(aggregate, bluebook))
          parts << "**How it moves**" << fence(Mermaid.lifecycle(aggregate)) if aggregate.lifecycle
          statements = always_true(aggregate, bluebook)
          parts << "**Always true**" << statements.map { |statement| "- #{statement}" }.join("\n") unless statements.empty?
          unless marked.empty?
            lines = marked.map { |marking| "- #{Sensitivity.sentence(marking)}" }
            parts << "**Handled as sensitive**" << lines.join("\n")
          end
          parts
        end

        # The statements projection's own sentences, spoken. An invariant
        # is the author's words and stays exactly so. A relationship
        # sentence is built mechanically from construct names ("An
        # ATMCard references an Account."), and a construct name is the
        # one thing this page never shows as an identifier — so each is
        # replaced with how it is said, whole-word, and nothing else in
        # the sentence is touched.
        #
        # @param aggregate [Bluebook::Aggregate] the aggregate to gather rules for
        # @param bluebook [Bluebook::Behaviour::Chapter] the chapter to read every
        #   construct name from, for de-identifying relationship sentences
        # @return [Array<String>] `aggregate`'s (and its entities') attribute and
        #   invariant statements, spoken and deduplicated
        def always_true(aggregate, bluebook)
          names = bluebook.aggregates.flat_map { |other| [other.hecks_name, *other.entities.map(&:hecks_name)] }
          [aggregate, *aggregate.entities].flat_map do |holder|
            Statements.attribute_statements(holder).map { |sentence| spoken(sentence, names) } +
              Statements.invariant_statements(holder)
          end.uniq
        end

        # Replaces every whole-word construct name in `sentence` with how it is said.
        #
        # @param sentence [String] the sentence to de-identify
        # @param names [Array<String>] every construct name to replace, whole-word
        # @return [String] `sentence` with each name in `names` replaced by
        #   `Naming.words(name)`
        def spoken(sentence, names)
          names.reduce(sentence) { |text, name| text.gsub(/\b#{Regexp.escape(name)}\b/, Naming.words(name)) }
        end

        # Renders one term's `###` heading and its paragraphs.
        #
        # @param entry [Glossary::Entry] the term to render
        # @param index [Glossary::Index] the document's link index
        # @return [String] the term's Markdown source
        def term_text(entry, index)
          ["### #{entry.headword}", *Sentences.paragraphs(entry, index)].join("\n\n")
        end

        # Wraps a Mermaid diagram's source in a fenced code block.
        #
        # @param source [String] a Mermaid diagram's own source
        # @return [String] `source` wrapped in a ` ```mermaid ` fence
        def fence(source) = "```mermaid\n#{source}\n```"
      end
    end
  end
end
