  # Hecks::Features::DomainMixin
  #
  # Adds vertical slice methods to Domain. Included automatically
  # when hecks_features is required.
  #
  #   domain.slices          # => [VerticalSlice, ...]
  #   domain.slices_diagram  # => Mermaid flowchart string
  #
module Hecks::Features

  module DomainMixin
    # Extract all vertical slices from this domain's reactive chains.
    #
    # @return [Array<VerticalSlice>]
    def slices
      SliceExtractor.new(self).extract
    end

    # Generate a Mermaid flowchart diagram of this domain's vertical slices.
    #
    # @return [String] Mermaid flowchart markup
    def slices_diagram
      SliceDiagram.new(self).generate
    end
  end
end
