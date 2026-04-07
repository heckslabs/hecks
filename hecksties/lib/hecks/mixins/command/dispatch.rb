# Hecks::Command::Dispatch
# Event construction and persistence for command execution.
# Included automatically via Hecks::Command.
#
# Usage: internal — called by LifecycleSteps during command execution.

module Hecks
  module Command
    # Hecks::Command::Dispatch
    #
    # Event construction and persistence helpers included automatically via Hecks::Command.
    #
    module Dispatch
      private

      # Persists the aggregate via the wired repository. Stamps created_at or
      # updated_at timestamps automatically if the aggregate supports them.
      #
      # @return [void]
      def persist_aggregate
        return unless aggregate
        if aggregate.respond_to?(:stamp_created!) && aggregate.created_at.nil?
          aggregate.stamp_created!
        elsif aggregate.respond_to?(:stamp_updated!)
          aggregate.stamp_updated!
        end
        repository.save(aggregate)
      end

      # Constructs a single event instance from the given event class.
      # Introspects the event class constructor to map command and aggregate
      # attributes into event parameters.
      #
      # @param event_class [Class] the event class to instantiate
      # @return [Object] the constructed event instance
      def build_event_for(event_class)
        event_params = event_class.instance_method(:initialize).parameters.map { |_, n| n }
        attrs = {}
        event_params.each do |param|
          if param == :aggregate_id && aggregate
            attrs[param] = aggregate.id
          elsif respond_to?(param, true)
            attrs[param] = send(param)
          elsif aggregate&.respond_to?(param)
            attrs[param] = aggregate.send(param)
          end
        end
        event_class.new(**attrs)
      end

      # Constructs all events declared via +emits+ without publishing them.
      #
      # @return [Array<Object>] all constructed event instances
      def build_events
        self.class.event_classes.map { |klass| build_event_for(klass) }
      end

      # Constructs the first event declared via +emits+ without publishing it.
      # Preserved for backward compatibility with dry_call and internal use.
      #
      # @return [Object] the constructed event instance
      def build_event
        build_event_for(self.class.event_class)
      end

      # Builds and publishes all events declared via +emits+ on the event bus.
      # Sets +@event+ to the first event for backward compatibility,
      # and +@events+ to the full array.
      #
      # @return [Array<Object>] all constructed and published event instances
      def emit_event
        @events = build_events
        @event = @events.first
        @events.each { |evt| self.class.event_bus&.publish(evt) }
        @events
      end

      # Records the emitted event in the event recorder for the aggregate,
      # enabling event sourcing and audit trails.
      #
      # @return [void]
      def record_event_for_aggregate
        recorder = self.class.event_recorder
        agg_type = self.class.aggregate_type
        recorder.record(agg_type, aggregate.id, @event) if recorder && aggregate
      end
    end
  end
end
