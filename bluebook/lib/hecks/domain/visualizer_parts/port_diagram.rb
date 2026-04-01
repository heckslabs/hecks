# Hecks::DomainVisualizer::PortDiagram
#
# Builds a Mermaid flowchart showing the hexagonal architecture of a domain:
# driving ports (HTTP, MCP, CLI, etc.) on the left, the domain hexagon in
# the center, and driven ports (persistence, auth, logging, etc.) on the
# right. Arrows show data flow direction.
#
# Extension metadata is read from Hecks.extension_meta when available.
# An explicit +extensions+ parameter can override this for testing.
#
#   include PortDiagram
#   generate_ports  # => "flowchart LR\n    subgraph Driving Ports\n..."
#
module Hecks
  class DomainVisualizer
    module PortDiagram
      # Generate a Mermaid flowchart showing driving ports, the domain
      # hexagon, and driven ports with directional arrows.
      #
      # @param extensions [Hash, nil] extension metadata hash; defaults to
      #   Hecks.extension_meta if available
      # @return [String] Mermaid flowchart source code
      def generate_ports(extensions: nil)
        meta = resolve_extension_meta(extensions)
        driving = extract_by_type(meta, :driving)
        driven  = extract_by_type(meta, :driven)

        lines = ["flowchart LR"]
        driving_nodes(lines, driving)
        domain_node(lines)
        driven_nodes(lines, driven)
        flow_arrows(lines, driving, driven)
        lines.join("\n")
      end

      private

      def resolve_extension_meta(explicit)
        return explicit if explicit
        return Hecks.extension_meta if defined?(Hecks.extension_meta) && Hecks.extension_meta.any?

        {}
      end

      def extract_by_type(meta, type)
        entries = meta.respond_to?(:select) ? meta.select { |_, m| m[:adapter_type] == type } : []
        entries.map { |name, m| { name: name, description: m[:description] } }
      end

      def driving_nodes(lines, driving)
        return if driving.empty?

        lines << "    subgraph Driving[\"Driving Ports\"]"
        driving.each do |ext|
          lines << "        #{port_id(ext[:name])}[\"#{ext[:name]}: #{ext[:description]}\"]"
        end
        lines << "    end"
      end

      def domain_node(lines)
        lines << "    Domain{{\"#{@domain.name}\"}}"
      end

      def driven_nodes(lines, driven)
        return if driven.empty?

        lines << "    subgraph Driven[\"Driven Ports\"]"
        driven.each do |ext|
          lines << "        #{port_id(ext[:name])}[\"#{ext[:name]}: #{ext[:description]}\"]"
        end
        lines << "    end"
      end

      def flow_arrows(lines, driving, driven)
        driving.each do |ext|
          lines << "    #{port_id(ext[:name])} --> Domain"
        end
        driven.each do |ext|
          lines << "    Domain --> #{port_id(ext[:name])}"
        end
      end

      def port_id(name)
        "port_#{name}"
      end
    end
  end
end
