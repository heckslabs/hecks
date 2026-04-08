# Hecks::DomainVisualizer::PortDiagram
#
# Builds two Mermaid flowcharts that expose the hexagonal architecture of a
# domain:
#
# 1. generate_ports — shows registered extension adapters. Driving adapters
#    (HTTP, MCP, CLI) appear on the left; driven adapters (persistence, auth,
#    logging) appear on the right. Arrows show data-flow direction.
#    Extension metadata is read from Hecks.extension_meta when available; an
#    explicit +extensions+ parameter can override this for testing.
#
# 2. generate_aggregate_ports — shows each aggregate's commands as driving
#    port arrows entering the aggregate from the left, and optional driven
#    port nodes (Persistence, EventBus) exiting to the right. Pass
#    +show_persistence: true+ and/or +show_event_bus: true+ to enable the
#    driven-port nodes.
#
#   include PortDiagram
#   generate_ports               # => "flowchart LR\n    subgraph Driving…"
#   generate_aggregate_ports     # => "flowchart LR\n    subgraph Pizza…"
#
module Hecks
  class BluebookVisualizer
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

      # Generate a Mermaid flowchart showing per-aggregate hexagonal ports.
      # Commands appear as driving-port nodes (left), the aggregate sits in
      # the centre, and optional persistence / event-bus nodes appear as
      # driven-port nodes (right).
      #
      # @param show_persistence [Boolean] include a Persistence node (default false)
      # @param show_event_bus   [Boolean] include an EventBus node (default false)
      # @return [String] Mermaid flowchart source code
      def generate_aggregate_ports(show_persistence: false, show_event_bus: false)
        lines = ["flowchart LR"]

        @domain.aggregates.each do |agg|
          lines << "    subgraph #{agg.name}"
          agg.commands.each do |cmd|
            cmd_node = "#{agg.name}_#{cmd.name}_cmd"
            lines << "        #{cmd_node}([#{cmd.name}])-->#{agg.name}"
          end
          if show_persistence
            lines << "        #{agg.name}-->#{agg.name}_Persistence[(Persistence)]"
          end
          if show_event_bus
            lines << "        #{agg.name}-->#{agg.name}_EventBus{{EventBus}}"
          end
          lines << "    end"
        end

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
