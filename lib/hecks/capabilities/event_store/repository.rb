# Hecks::Capabilities::EventStore::Repository
#
# Event-sourced repository adapter. Instead of storing aggregate state
# directly, it captures events from the event bus and rebuilds aggregates
# by replaying their event history through DSL-defined applier procs.
#
# Implements the same interface as the default memory repository so it
# can be swapped in via runtime.swap_adapter.
#
# == Usage
#
#   store = Store.new
#   repo = Repository.new(store, aggregate_class, appliers)
#   repo.save(aggregate)
#   found = repo.find("pizza-1")
#   repo.all  # => [aggregate, ...]
#
module Hecks
  module Capabilities
    module EventStore
      # Hecks::Capabilities::EventStore::Repository
      #
      # Repository adapter that persists via event streams and rebuilds via replay.
      #
      class Repository
        # @param store [Store] the event store instance
        # @param aggregate_class [Class] the runtime aggregate class
        # @param appliers [Hash{String => Proc}] event_type => apply block
        def initialize(store, aggregate_class, appliers)
          @store = store
          @aggregate_class = aggregate_class
          @appliers = appliers
        end

        # Save an aggregate by appending its pending event to the store.
        # The event is expected to be the most recent event on the bus
        # for this aggregate — captured via the event bus subscription.
        #
        # @param aggregate [Object] the aggregate instance (used for ID)
        # @return [Object] the aggregate
        def save(aggregate)
          # State is captured via event bus subscription in the capability
          # wiring, not here. Save is a no-op for event-sourced aggregates
          # because the event has already been appended by the bus listener.
          aggregate
        end

        # Find an aggregate by replaying its event history.
        #
        # @param id [String] the aggregate ID
        # @return [Object, nil] the reconstituted aggregate or nil
        def find(id)
          @store.replay(id, @aggregate_class, @appliers)
        end

        # Rebuild all aggregates from their event streams.
        #
        # @return [Array<Object>] all reconstituted aggregates
        def all
          @store.aggregate_ids.filter_map do |id|
            @store.replay(id, @aggregate_class, @appliers)
          end
        end

        # Count of aggregates with at least one event.
        #
        # @return [Integer]
        def count
          @store.aggregate_ids.size
        end

        # Delete all events for an aggregate.
        #
        # @param id [String] the aggregate ID
        # @return [void]
        def delete(id)
          @store.delete(id)
        end
      end
    end
  end
end
