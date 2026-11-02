# frozen_string_literal: true

require "json"
require_relative "probe"
require_relative "pipeline_wiring/graph"

module Hecks
  module Adapters
    # The `Wiring` port's adapter: answers `Wiring` with what the loaded bluebooks wire together,
    # for the diagram: which aggregate's events a policy listens to, which aggregate's command it
    # reaches, which port an `ask` goes out through, and which adapter answers each port. It reads
    # the booted registry and nothing else, and changes nothing.
    class PipelineWiring
      # @param registry [Runtime::Registry, nil] the booted registry whose bluebooks are read
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(registry: nil, aggregate: nil, settings: {}, root: nil)
        @registry = registry
      end

      # @return [Hash{Symbol => String}] `text:` the graph as JSON: `nodes` and `edges`
      # @raise [PipelineBoard::Unavailable] when no registry is booted here
      def wiring = { text: JSON.generate(graph) }

      # @return [Hash] `nodes` (aggregates, ports, adapters) and `edges` (policy, ask, adapter)
      # @raise [PipelineBoard::Unavailable] when no registry is booted here
      def graph
        raise PipelineBoard::Unavailable, "no domain is booted here to read the wiring from" unless @registry

        @graph ||= PipelineBoard::Graph.new(@registry).to_h
      end
    end
  end
end
