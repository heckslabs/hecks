require_relative "visualizer_parts/structure_diagram"
require_relative "visualizer_parts/behavior_diagram"
require_relative "visualizer_parts/port_diagram"

module Hecks
  # Hecks::DomainVisualizer
  #
  # Generates Mermaid diagram strings from a domain IR. Produces two diagrams:
  # 1. A classDiagram (structure) showing aggregates, attributes, value objects,
  #    entities, and inter-aggregate references
  # 2. A flowchart (behavior) showing command-to-event flows and policy chains
  #
  # Both diagrams are wrapped in markdown code fences for direct embedding
  # in documentation or README files.
  #
  #   Hecks::DomainVisualizer.new(domain).generate  # => "```mermaid\n..."
  #   Hecks::DomainVisualizer.new(domain).print      # prints to stdout
  #   Hecks.visualize(domain)                         # top-level shortcut
  #
  class DomainVisualizer
    include StructureDiagram
    include BehaviorDiagram
    include PortDiagram

    # @param domain [Hecks::DomainModel::Domain] the domain IR to visualize
    def initialize(domain)
      @domain = domain
    end

    # Generate both the structure and behavior Mermaid diagrams as a single
    # markdown string with two code-fenced blocks.
    #
    # @return [String] markdown with two ```mermaid blocks (structure then behavior)
    def generate
      parts = []
      parts << "```mermaid"
      parts << generate_structure
      parts << "```"
      parts << ""
      parts << "```mermaid"
      parts << generate_behavior
      parts << "```"
      parts.join("\n")
    end

    # Print the generated diagrams to stdout.
    #
    # @return [nil]
    def print
      puts generate
      nil
    end
  end
end
