# frozen_string_literal: true

require "json"
require "digest"
require_relative "probe"
require_relative "rules"
require_relative "pipeline_wiring/details"
require_relative "pipeline_wiring/graph"
require_relative "pipeline_wiring/source"

module Hecks
  module Adapters
    # The `Wiring` port's adapter: answers `Wiring` with what the loaded bluebooks wire together,
    # for the diagram: which aggregate's events a policy listens to, which aggregate's command it
    # reaches, which port an `ask` goes out through, and which adapter answers each port. It reads
    # the bluebook files the booted registry was declared from and changes nothing: the graph is
    # drawn from the registry at first, and drawn again from the files whenever one of them changes,
    # without booting them.
    class PipelineWiring
      # @param registry [Runtime::Registry, nil] the booted registry whose bluebooks are read
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `source:` stands in for {PipelineBoard::WiringSource};
      #   `look_seconds:` for the `wiring_look_seconds` setting
      # @param root [String, nil] unused
      def initialize(registry: nil, aggregate: nil, settings: {}, root: nil)
        @registry = registry
        seconds = settings[:look_seconds]
        @look_seconds = seconds ? -> { seconds } : -> { PipelineBoard::Rules.setting("wiring_look_seconds") }
        @source = settings[:source] || (registry && PipelineBoard::WiringSource.new(registry))
        @lock = Mutex.new
        @stamp = @source&.stamp
      end

      # @return [Hash{Symbol => String}] `text:` the graph as JSON: `nodes` and `edges`
      # @raise [PipelineBoard::Unavailable] when no registry is booted here
      def wiring = { text: JSON.generate(graph) }

      # @return [Hash] `nodes` (aggregates, ports, adapters) and `edges` (policy, ask, adapter),
      #   as the bluebook files declare them now
      # @raise [PipelineBoard::Unavailable] when no registry is booted here
      def graph = reading.except(:digest)

      # @return [Hash] the graph with its `digest`, which differs whenever the wiring does; both
      #   from the same look at the files
      # @raise [PipelineBoard::Unavailable] when no registry is booted here
      def reading
        raise PipelineBoard::Unavailable, "no domain is booted here to read the wiring from" unless @registry

        @lock.synchronize do
          refresh
          @graph.merge(digest: @digest)
        end
      end

      # @return [String] the digest of the graph
      # @raise [PipelineBoard::Unavailable] when no registry is booted here
      def digest = reading[:digest]

      # @return [String, nil] why the files could not be read the last time one changed; the graph
      #   stays the last one that drew
      attr_reader :problem

      private

      # Looks at the bluebook files once in `wiring_look_seconds` at most: every open stream asks
      # on every journal line, and a look stats every declaration file.
      def refresh
        due = look_due?
        return if @graph && !due

        stamp = @source.stamp
        return seed if @graph.nil? && stamp == @stamp
        return if stamp == @stamp

        @stamp = stamp
        rebuild
      end

      # The graph of the booted registry, drawn before any file has changed.
      def look_due?
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return false if @looked && now - @looked < @look_seconds.call

        @looked = now
        true
      end

      def seed = store(PipelineBoard::Graph.new(@registry).to_h)

      def rebuild
        store(PipelineBoard::Graph.new(@source.read).to_h)
      rescue StandardError, ScriptError => e
        seed unless @graph
        @problem = "#{e.class}: #{e.message}"
      end

      def store(graph)
        @graph = graph
        @digest = Digest::SHA1.hexdigest(JSON.generate(graph))
        @problem = nil
      end
    end
  end
end
