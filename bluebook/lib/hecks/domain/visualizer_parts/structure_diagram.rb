module Hecks
  class DomainVisualizer
    # Hecks::DomainVisualizer::StructureDiagram
    #
    # Builds the Mermaid classDiagram portion showing aggregates, attributes,
    # value objects, entities, and inter-aggregate references. Mixed into
    # DomainVisualizer.
    #
    # Aggregates are rendered as classes with their attributes. Value objects
    # and entities are rendered as separate classes composed into (*--) their
    # parent aggregate. Entities additionally show a +id : UUID attribute.
    # Cross-aggregate references are drawn as directed associations (-->).
    #
    #   include StructureDiagram
    #   generate_structure  # => "classDiagram\n    class Pizza { ... }\n"
    #
    module StructureDiagram
      # Generate the complete Mermaid classDiagram string for the domain's
      # structural model. Includes classes for aggregates, value objects,
      # and entities, plus composition and reference relationships.
      #
      # @return [String] Mermaid classDiagram source code
      def generate_structure
        lines = ["classDiagram"]

        @domain.aggregates.each do |agg|
          lines << "    class #{agg.name} {"
          agg.attributes.each do |attr|
            lines << "        #{attribute_label(attr)}"
          end
          lines << "    }"

          agg.value_objects.each do |vo|
            lines << "    class #{vo.name} {"
            vo.attributes.each do |attr|
              lines << "        #{attribute_label(attr)}"
            end
            lines << "    }"
            lines << "    #{agg.name} *-- #{vo.name}"
          end

          agg.entities.each do |ent|
            lines << "    class #{ent.name} {"
            lines << "        +id : UUID"
            ent.attributes.each do |attr|
              lines << "        #{attribute_label(attr)}"
            end
            lines << "    }"
            lines << "    #{agg.name} *-- #{ent.name}"
          end
        end

        references(lines)
        lines.join("\n")
      end

      private

      # Format an attribute for display in a Mermaid class diagram.
      # List attributes show as +Type[] name+, references show as
      # +String name+ (since they store IDs), and scalars show as
      # +Type name+.
      #
      # @param attr [Hecks::BluebookModel::Attribute] the attribute to format
      # @return [String] Mermaid-formatted attribute line (e.g., "+String name")
      def attribute_label(attr)
        if attr.list?
          "+#{attr.type}[] #{attr.name}"
        else
          "+#{attr.type} #{attr.name}"
        end
      end

      # Add cross-aggregate reference arrows to the diagram. Scans all
      # aggregates for declared references and draws a directed
      # association to the referenced aggregate.
      #
      # @param lines [Array<String>] the diagram lines array to append to
      # @return [void]
      def references(lines)
        @domain.aggregates.each do |agg|
          (agg.references || []).each do |ref|
            lines << "    #{agg.name} --> #{ref.type} : #{ref.name}"
          end
        end
      end
    end
  end
end
