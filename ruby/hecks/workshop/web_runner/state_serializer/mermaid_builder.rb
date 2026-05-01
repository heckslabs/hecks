module Hecks
  class Workshop
    class WebRunner
      class StateSerializer
        # Hecks::Workshop::WebRunner::StateSerializer::MermaidBuilder
        #
        # Builds a Mermaid LR graph string from serialized aggregates.
        # Nodes show attribute and command counts; edges represent
        # reference_to (solid) and list_of (dashed) relationships.
        #
        #   MermaidBuilder.new(aggregates).call
        #   # => "graph LR\n  Pizza[\"Pizza<br/>...\"]"
        #
        class MermaidBuilder
          def initialize(aggregates)
            @aggregates = aggregates
          end

          def call
            lines = ["graph LR"]
            agg_names = @aggregates.map { |a| a[:name] }
            @aggregates.each { |agg| lines << node_line(agg) }
            @aggregates.each { |agg| edge_lines(agg, agg_names, lines) }
            lines.join("\n")
          end

          private

          def node_line(agg)
            name = agg[:name]
            count = agg[:attributes].size
            cmds = agg[:commands].size
            "  #{name}[\"#{name}<br/><small>#{count} attrs · #{cmds} cmds</small>\"]"
          end

          def edge_lines(agg, agg_names, lines)
            agg[:attributes].each do |a|
              type_s = a[:type].to_s
              if type_s.include?("reference_to")
                add_edge(lines, agg[:name], a, type_s, "reference_to", "-->", agg_names)
              elsif type_s.include?("list_of")
                add_edge(lines, agg[:name], a, type_s, "list_of", "-.->", agg_names)
              end
            end
          end

          def add_edge(lines, source, attr, type_s, wrapper, arrow, agg_names)
            target = type_s.gsub(/#{wrapper}\(|\)|"/, "").strip
            label = attr[:name].to_s.sub(/_id$/, "")
            lines << "  #{source} #{arrow}|#{label}| #{target}" if agg_names.include?(target)
          end
        end
      end
    end
  end
end
