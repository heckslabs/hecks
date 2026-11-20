require_relative "../../runtime/registry"
require_relative "../../runtime/dispatch_claim"
require_relative "outbox_delivery/delivery_shape"

module Hecks
  module Adapters
    # The `event_delivery` port answered by the Ruby outbox (ADR 0178): `Relay` and its row stores
    # (`Memory::OutboxRows`, `Sqlite::Outbox`, `Postgres::Outbox`) hold the deliveries, and each
    # repository declaring `:dispatch_claims` holds the dispatches already answered. It reads them
    # and changes nothing.
    module OutboxDelivery
      module_function

      # Every outbox row across every bound store, shaped as a `Delivery`.
      #
      # @param registry [Runtime::Registry] the booted registry whose relay holds the rows
      # @param status [String, nil] only rows in this state; nil answers all
      # @return [Array<Hash{Symbol => Object}>] one `Delivery`-shaped hash per row
      def deliveries(registry, status: nil)
        registry.outbox.rows(status: status).map { |row| DeliveryShape.of(row) }
      end

      # Whether any store that dedupes dispatches has applied one under `key`.
      #
      # @param registry [Runtime::Registry] the booted registry
      # @param key [String] the dispatch's key, as `Runtime::DispatchClaim.key` builds it
      # @return [Boolean] true once a store holds the key
      def reacted?(registry, key:)
        claim_stores(registry).any? { |repository| repository.dispatch_applied?(key) }
      end

      # Every bound repository that dedupes dispatches. An aggregate its hecksagon left unbound
      # raises `WiringError` and is skipped, as the relay skips it.
      #
      # @param registry [Runtime::Registry] the booted registry
      # @return [Array] the repositories declaring `:dispatch_claims`
      def claim_stores(registry)
        registry.bluebooks.each_value.flat_map do |bluebook|
          bluebook.aggregates.filter_map { |aggregate| claim_store(registry, bluebook, aggregate) }
        end
      end

      # @return [Object, nil] the aggregate's repository when it dedupes dispatches
      def claim_store(registry, bluebook, aggregate)
        repository = registry.repository(bluebook.name, aggregate)
        repository if Runtime::DispatchClaim.supported?(repository)
      rescue Runtime::WiringError
        nil
      end
    end
  end
end
