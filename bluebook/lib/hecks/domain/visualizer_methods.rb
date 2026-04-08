  # Hecks::DomainVisualizerMethods
  #
  # Top-level entry point for Mermaid diagram generation. Extended onto
  # the Hecks module to provide +Hecks.visualize(domain)+ as a convenience
  # method that delegates to DomainVisualizer.
  #
  #   Hecks.visualize(domain)  # => "```mermaid\nclassDiagram\n..."
  #
module Hecks
  module DomainVisualizerMethods
    # Generate Mermaid diagrams (structure and behavior) for a domain.
    #
    # @param domain [Hecks::BluebookModel::Domain] the domain to visualize
    # @return [String] markdown string with two ```mermaid code blocks
    def visualize(domain)
      DomainVisualizer.new(domain).generate
    end
  end
end
