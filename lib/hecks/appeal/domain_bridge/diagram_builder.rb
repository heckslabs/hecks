# Hecks::Appeal::DomainBridge::DiagramBuilder
#
# Mixin for DomainBridge that generates Mermaid diagrams from domain IR.
# Produces structure, behavior, flow, and overview diagrams plus
# animation graph data for the canvas background.
#
#   bridge.diagram(project_path, domain_name, :structure)
#   bridge.domain_overview  # => "graph TD\n..."
#
module Hecks
  module Appeal
    class DomainBridge
      module DiagramBuilder
        # Generate a Mermaid diagram for a domain.
        #
        # @param project_path [String] path to the project
        # @param domain_name [String] which domain
        # @param view [Symbol] :structure, :behavior, or :flow
        # @return [String] Mermaid markup
        def diagram(project_path, domain_name, view = :structure)
          project = @projects[project_path]
          return "" unless project

          domain_info = project[:domains].find { |d| d[:name] == domain_name }
          return "" unless domain_info

          domain = domain_info[:domain]
          case view
          when :structure
            Hecks::DomainVisualizer.new(domain).generate_structure
          when :behavior
            Hecks::DomainVisualizer.new(domain).generate_behavior
          when :flow
            Hecks::FlowGenerator.new(domain).generate_mermaid
          end
        rescue => e
          "%% Diagram error: #{e.message}"
        end

        # All three diagram types for a domain.
        #
        # @param project_path [String]
        # @param domain_name [String]
        # @return [Hash] { structure:, behavior:, flow: }
        def diagrams_for(project_path, domain_name)
          {
            structure: diagram(project_path, domain_name, :structure),
            behavior: diagram(project_path, domain_name, :behavior),
            flow: diagram(project_path, domain_name, :flow)
          }
        end

        # Cross-domain overview diagram showing all domains and relationships.
        # Delegates to Hecks::ContextMapGenerator for accurate event-flow arrows.
        #
        # @return [String] Mermaid markup
        def domain_overview
          domain_objects = all_domains.filter_map { |d| d[:domain] }
          return "graph TD\n  empty[\"No domains loaded\"]" if domain_objects.empty?
          Hecks::ContextMapGenerator.new(domain_objects).generate
        end

        # Graph data for the canvas animation.
        #
        # @return [Hash] { nodes: [String], edges: [[Integer, Integer]] }
        def animation_graph
          names = all_domains.flat_map { |d| d[:aggregates]&.map { |a| a[:name] } || [] }
          edges = all_domains.flat_map { |d|
            (d[:aggregates] || []).flat_map { |agg|
              (agg[:references] || []).filter_map { |ref|
                from, to = names.index(agg[:name]), names.index(ref)
                [from, to] if from && to
              }
            }
          }
          { nodes: names, edges: edges }
        end
      end
    end
  end
end
