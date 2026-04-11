Hecks::Chapters.load_aggregates(
  Hecks::Bluebook::VisualizersParagraph,
  base_dir: File.expand_path("visualizer_parts", __dir__)
)
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

module Hecks
  class BluebookVisualizer
    include StructureDiagram
    include BehaviorDiagram
    include PortDiagram

    # @param domain [Hecks::BluebookModel::Domain] the domain IR to visualize
    def initialize(domain)
      @domain = domain
    end

    # Generate the structure, behavior, and aggregate-ports Mermaid diagrams
    # as a single markdown string with three code-fenced blocks.
    #
    # @param show_persistence [Boolean] include Persistence driven-port nodes
    # @param show_event_bus   [Boolean] include EventBus driven-port nodes
    # @return [String] markdown with three ```mermaid blocks
    def generate(show_persistence: false, show_event_bus: false)
      parts = []
      parts << "```mermaid"
      parts << generate_structure
      parts << "```"
      parts << ""
      parts << "```mermaid"
      parts << generate_behavior
      parts << "```"
      parts << ""
      parts << "```mermaid"
      parts << generate_aggregate_ports(
        show_persistence: show_persistence,
        show_event_bus: show_event_bus
      )
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
