# Hecks::Capabilities::ProjectDiscovery::DiagramBuilder
#
# Mixin for Bridge that generates Mermaid diagrams from domain IR.
# Produces structure, behavior, flow, and overview diagrams plus
# animation graph data for the canvas background.
#
#   bridge.diagram(project_path, domain_name, :structure)
#   bridge.domain_overview  # => "graph TD\n..."
#
module Hecks
  module Capabilities
    module ProjectDiscovery
      module DiagramBuilder
        def diagram(project_path, domain_name, view = :structure)
          project = @projects[project_path]
          return "" unless project

          domain_info = project[:domains].find { |d| d[:name] == domain_name }
          return "" unless domain_info

          domain = domain_info[:domain]
          case view
          when :structure
            Hecks::BluebookVisualizer.new(domain).generate_structure
          when :behavior
            Hecks::BluebookVisualizer.new(domain).generate_behavior
          when :flow
            Hecks::FlowGenerator.new(domain).generate_mermaid
          end
        rescue => e
          "%% Diagram error: #{e.message}"
        end

        def diagrams_for(project_path, domain_name)
          {
            structure: diagram(project_path, domain_name, :structure),
            behavior: diagram(project_path, domain_name, :behavior),
            flow: diagram(project_path, domain_name, :flow)
          }
        end

        def domain_overview
          domain_objects = all_domains.filter_map { |d| d[:domain] }
          return "graph TD\n  empty[\"No domains loaded\"]" if domain_objects.empty?
          Hecks::ContextMapGenerator.new(domain_objects).generate
        end

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
