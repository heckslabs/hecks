require_relative "../naming"

module Hecks
  module Projector
    # Projects a bluebook as its own usage documentation, in Markdown.
    # Reach it as `Projector.call(:docs, bluebook: ...)` or `Domain.docs`.
    module DocsProjector
      module_function

      # Projects `bluebook` as Markdown usage documentation.
      #
      # @param bluebook [Bluebook::Behaviour::Chapter] the chapter to document
      # @param options [Hash] optional inputs
      # @option options [Integer, String] :heading the top heading level; defaults to 1
      # @option options [String, Symbol, nil] :aggregate narrows the document to one
      #   aggregate, omitting the chapter header and closing sections
      # @return [String] the document, ending in a newline
      # @raise [Runtime::NotFound] if `options[:aggregate]` names no declared aggregate
      def call(bluebook:, options: {})
        depth = (options[:heading] || 1).to_i
        only  = options[:aggregate]

        out = []
        out << chapter_header(bluebook, depth) unless only
        out.concat(aggregate_sections(bluebook, only, depth))
        out << Closing.call(bluebook, depth + 1) unless only
        "#{out.compact.join("\n").rstrip}\n"
      end

      # One section per aggregate; those of a narrowed document sit at the top heading level.
      def aggregate_sections(bluebook, only, depth)
        Array(aggregates(bluebook, only)).map { |aggregate| aggregate_section(aggregate, only ? depth : depth + 1) }
      end

      # An unknown aggregate name is refused rather than answered with an empty document.
      def aggregates(bluebook, only)
        return bluebook.aggregates unless only

        bluebook.aggregates.find { |aggregate| aggregate.hecks_name == only.to_s } ||
          raise(Runtime::NotFound,
                "#{bluebook.name} declares no aggregate named #{only.to_s.inspect} — " \
                "it declares #{bluebook.aggregates.map(&:hecks_name).sort.join(", ")}")
      end

      def h(depth, text) = "#{"#" * depth} #{text}"

      def chapter_header(bluebook, depth)
        out = [h(depth, bluebook.name), ""]
        out += ["> #{bluebook.vision}", ""] if bluebook.vision
        out.concat(classification_lines(bluebook))
        out << ""
        out << "Aggregates: #{aggregate_links(bluebook)}."
        out << ""
        out.join("\n")
      end

      # What kind of domain the chapter is and the name it is also known by, when declared.
      def classification_lines(bluebook)
        out = []
        out << "#{bluebook.classification.to_s.capitalize} domain." if bluebook.classification
        out << "Previously known as `#{bluebook.formerly_known_as}`." if bluebook.formerly_known_as
        out
      end

      # Each aggregate's name as a link to its section.
      def aggregate_links(bluebook)
        bluebook.aggregates.map { |a| "[#{a.hecks_name}](##{anchor(a.hecks_name)})" }.join(", ")
      end

      def anchor(name) = Naming.snake(name).tr("_", "-")

      def aggregate_section(aggregate, depth)
        out = opening_lines(depth, aggregate.hecks_name, aggregate.description)
        out.concat(identity_lines(aggregate))
        out << ""
        out.concat(holder_parts(aggregate, depth + 1))
        aggregate.entities.each { |entity| out << entity_section(aggregate, entity, depth + 1) }

        out.compact.join("\n")
      end

      # A section's heading, then its description when it has one.
      def opening_lines(depth, title, description)
        out = [h(depth, title), ""]
        out += [description, ""] if description
        out
      end

      # What identifies an aggregate and which records it references.
      def identity_lines(aggregate)
        out = []
        out << "Identified by `#{aggregate.identity_heads.join("`, `")}`." unless aggregate.identity_heads.empty?
        refs = aggregate.attributes.select(&:reference?)
        out << "References #{refs.map { |r| "`#{r.type.target_name}`" }.join(", ")}." unless refs.empty?
        out
      end

      # The attribute table, lifecycle, verbs and questions of an aggregate or entity.
      def holder_parts(holder, depth)
        [Attributes.table_for(holder), Behaviour.lifecycle_section(holder, depth),
         Behaviour.verbs_section(holder, depth),
         Behaviour.queries_section(holder.queries, depth, "Questions you can ask")]
      end

      def entity_section(aggregate, entity, depth)
        out = opening_lines(depth, "#{entity.hecks_name} (within #{aggregate.hecks_name})", entity.description)
        out << entity_addressing(aggregate, entity)
        out << ""
        out.concat(holder_parts(entity, depth + 1))
        out.compact.join("\n")
      end

      # An entity has no entry point of its own; its verbs go through the holding aggregate.
      def entity_addressing(aggregate, entity)
        "Addressed through its holder — `#{aggregate.hecks_name}.#{entity.hecks_name}.<Verb>`, " \
          "passing the #{aggregate.hecks_name}'s `id` and this element's " \
          "`#{entity.identity_heads.join("`, `")}`."
      end

      def table(headers, rows)
        lines = ["| #{headers.join(" | ")} |", "|#{headers.map { "---" }.join("|")}|"]
        rows.each { |row| lines << "| #{row.join(" | ")} |" }
        (lines + [""]).join("\n")
      end
    end
  end
end

require_relative "docs_projector/attributes"
require_relative "docs_projector/behaviour"
require_relative "docs_projector/closing"
