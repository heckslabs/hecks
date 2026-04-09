# Hecks::Capabilities::EventStore::Store
#
# In-memory event store for the event_store capability. Wraps the
# lower-level EventSourcing::EventStore with a simpler append/query
# interface suited to capability wiring.
#
# == Usage
#
#   store = Store.new
#   store.append("Pizza-1", event)
#   store.events_for("Pizza-1")  # => [event, ...]
#   store.all_events              # => [event, ...]
#   state = store.replay("Pizza-1", PizzaClass, appliers)
#
module Hecks
  module Capabilities
    module EventStore
      # Hecks::Capabilities::EventStore::Store
      #
      # In-memory append-only event store with replay support for aggregate reconstitution.
      #
      class Store
        def initialize
          @streams = Hash.new { |h, k| h[k] = [] }
        end

        # Append a domain event to the stream for the given aggregate ID.
        #
        # @param aggregate_id [String] the aggregate instance ID
        # @param event [Object] the domain event object
        # @return [void]
        def append(aggregate_id, event)
          @streams[aggregate_id.to_s] << event
        end

        # Return all events for a specific aggregate ID, in append order.
        #
        # @param aggregate_id [String] the aggregate instance ID
        # @return [Array<Object>] ordered list of events
        def events_for(aggregate_id)
          @streams[aggregate_id.to_s].dup
        end

        # Return every event across all streams, in per-stream append order.
        #
        # @return [Array<Object>] all stored events
        def all_events
          @streams.values.flatten
        end

        # Return all aggregate IDs that have at least one event.
        #
        # @return [Array<String>] aggregate IDs with events
        def aggregate_ids
          @streams.keys
        end

        # Replay events for an aggregate, building state through applier procs.
        # Creates a new aggregate instance and applies each event through the
        # matching applier block from the DSL.
        #
        # @param aggregate_id [String] the aggregate instance ID
        # @param aggregate_class [Class] the runtime aggregate class
        # @param appliers [Hash{String => Proc}] event_type => apply block
        # @return [Object, nil] the reconstituted aggregate, or nil if no events
        def replay(aggregate_id, aggregate_class, appliers)
          events = events_for(aggregate_id)
          return nil if events.empty?

          instance = aggregate_class.allocate
          instance.instance_variable_set(:@id, aggregate_id)
          events.each do |event|
            event_type = Hecks::Utils.const_short_name(event)
            applier = appliers[event_type]
            instance.instance_exec(event, &applier) if applier
          end
          instance
        end

        # Remove all events for a specific aggregate ID.
        #
        # @param aggregate_id [String] the aggregate instance ID
        # @return [void]
        def delete(aggregate_id)
          @streams.delete(aggregate_id.to_s)
        end

        # Remove all stored events across all streams.
        #
        # @return [void]
        def clear
          @streams.clear
        end
      end
    end
  end
end
