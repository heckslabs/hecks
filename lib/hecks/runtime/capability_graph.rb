module Hecks
  module Runtime
    # Which ports a boot can fulfill: each declared port matched to the adapters wired to it,
    # so a wiring gap can be asked about before a dispatch refuses.
    class CapabilityGraph
      # @param registry [Runtime::Registry] the booted registry to read ports and adapters from
      # @return [void]
      def initialize(registry)
        @registry = registry
      end

      # Maps each declared port's name to the names of its adapters, unfulfilled ports included.
      #
      # @return [Hash{String => Array<String>}] each declared port's name mapped to the names
      #   of every adapter bound to it (empty when none are)
      def fulfillments
        @fulfillments ||= @registry.ports.each_key.to_h { |name| [name, adapters_for(name)] }
      end

      # The ports with zero adapters bound.
      #
      # @return [Array<String>] the names of every declared port with no adapter bound to it
      def unfulfilled
        fulfillments.select { |_, adapters| adapters.empty? }.keys
      end

      # Reports the port-dependency cycles; always none, as a port cannot depend on another port.
      #
      # @return [Array] always empty
      def cycles = []

      private

      def adapters_for(port_name)
        @registry.adapters.values.select { |adapter| adapter.port == port_name }.map(&:name)
      end
    end
  end
end
