# frozen_string_literal: true

require "hecks/runtime/adapter_lookup"

module Hecks
  module Adapters
    class GitLanding
      # The ground other work holds: the adapter the project bound to the `Claims` port.
      #
      # Delivery keeps no list of work in progress and no rule for when two areas overlap; a
      # pipeline that stands above it does, and says so through this port. It is asked for the
      # claims that stand, each with the areas it holds, and whether one area holds one changed
      # file. A project that binds no adapter has no claims, and nothing overlaps.
      class BoundClaims
        # The port a project binds what holds ground to.
        PORT = "Claims"

        # @param registry [Runtime::Registry, nil] the booted registry whose adapters are searched
        def initialize(registry)
          @registry = registry
        end

        # @return [Array<Hash{Symbol => Object}>] `key:` and `area:` of each claim that stands;
        #   empty when the project binds no adapter
        def items
          adapter ? adapter.read_claims[:claims] : []
        end

        # @param area [String] an area a claim holds
        # @param file [String] a file a landing changes
        # @param root [String] the repository's top level
        # @return [Boolean] whether the area holds the file; false when the project binds no
        #   adapter
        def overlap?(area, file, root)
          adapter ? adapter.overlap(area: area, file: file, root: root)[:overlaps] : false
        end

        private

        # A landing made with no booted registry has no project, and so nothing above it.
        def adapter
          return unless @registry.respond_to?(:adapters)
          return unless @registry.adapters.values.any? { |bound| bound.port == PORT }

          @adapter ||= Runtime::AdapterLookup.call(@registry, PORT, asked: "what ground other work holds")
        end
      end
    end
  end
end
