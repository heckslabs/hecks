require_relative "../runtime/registry"

module Hecks
  module Ports
    # What EventDelivery's model asks of the store that carries events to their consumers (ADR
    # 0178): the deliveries it holds and whether a dispatch is already answered. One adapter
    # registry-wide answers; the Ruby outbox is the one EventDelivery ships.
    #
    # **A read model of the outbox.** `deliveries` reads the outbox's own rows, shaped as the
    # `Delivery` aggregate. The `Delivery` records in EventDelivery's own repository are not
    # written by the runtime, so read deliveries here, not from that aggregate.
    module EventDelivery
      NAME = "event_delivery".freeze

      module_function

      # Every delivery the bound store holds, in the `Delivery` aggregate's attribute shape.
      #
      # @param registry [Runtime::Registry] the booted registry to resolve the adapter against
      # @param status [String, nil] only deliveries in this lifecycle state; nil answers all
      # @return [Array<Hash{Symbol => Object}>] one per delivery, oldest first within a store
      # @raise [Runtime::WiringError] if this port does not resolve to exactly one adapter
      def deliveries(registry, status: nil) = adapter(registry).deliveries(registry, status: status)

      # Whether the dispatch with this key has already been answered.
      #
      # @param registry [Runtime::Registry] the booted registry to resolve the adapter against
      # @param key [String] the dispatch's key, as `Runtime::DispatchClaim.key` builds it
      # @return [Boolean] true once some store has applied a dispatch under `key`
      # @raise [Runtime::WiringError] if this port does not resolve to exactly one adapter
      def reacted?(registry, key:) = adapter(registry).reacted?(registry, key: key)

      # Finds the single adapter bound to this port.
      #
      # @param registry [Runtime::Registry] the booted registry
      # @return [Module] the adapter implementation
      # @raise [Runtime::WiringError] if none, or more than one, implements this port
      def adapter(registry)
        implementations = registry.adapters.values.select { |a| a.port == NAME }
        return registry.adapter_class(implementations.first.name) if implementations.size == 1

        raise Runtime::WiringError, wiring_refusal(implementations)
      end

      # Words the refusal for a port that resolves to no adapter or to several.
      #
      # @param implementations [Array] the adapters bound to this port
      # @return [String] the error message
      def wiring_refusal(implementations)
        return "no adapter implements the #{NAME} port — attach EventDelivery to bind the outbox" if implementations.empty?

        names = implementations.map(&:name).sort.join(", ")
        "#{implementations.size} adapters implement the #{NAME} port (#{names}) — the runtime will not choose for you"
      end
    end
  end
end
