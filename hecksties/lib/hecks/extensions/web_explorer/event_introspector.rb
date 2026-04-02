# Hecks::WebExplorer::EventIntrospector
#
# Reads the EventBus events array and provides filtered views for the
# web explorer event log page. Derives event type and aggregate name
# from each event's fully qualified class name.
#
#   introspector = EventIntrospector.new(event_bus)
#   introspector.all_entries(type_filter: "CreatedPizza")
#   introspector.event_types   # => ["CreatedPizza", "PlacedOrder"]
#   introspector.aggregate_types  # => ["Pizza", "Order"]
#
module Hecks
  module WebExplorer
    class EventIntrospector
      def initialize(event_bus)
        @event_bus = event_bus
      end

      # Returns all event entries, newest first.
      #
      # @param type_filter [String, nil] restrict to this event type name
      # @param aggregate_filter [String, nil] restrict to this aggregate name
      # @return [Array<Hash>] entries with :type, :aggregate, :occurred_at, :payload
      def all_entries(type_filter: nil, aggregate_filter: nil)
        entries = @event_bus.events.map { |e| build_entry(e) }.reverse
        entries = entries.select { |e| e[:type] == type_filter } if type_filter && !type_filter.empty?
        entries = entries.select { |e| e[:aggregate] == aggregate_filter } if aggregate_filter && !aggregate_filter.empty?
        entries
      end

      # Unique event type names across all stored events.
      #
      # @return [Array<String>]
      def event_types
        @event_bus.events.map { |e| short_name(e) }.uniq
      end

      # Unique aggregate names across all stored events.
      #
      # @return [Array<String>]
      def aggregate_types
        @event_bus.events.map { |e| aggregate_name(e) }.uniq
      end

      private

      def build_entry(event)
        {
          type: short_name(event),
          aggregate: aggregate_name(event),
          occurred_at: extract_occurred_at(event),
          payload: extract_payload(event)
        }
      end

      def short_name(event)
        Hecks::Utils.const_short_name(event)
      end

      # Derive aggregate name from module path: DomainModule::AggregateName::Events::EventType
      def aggregate_name(event)
        parts = event.class.name.to_s.split("::")
        idx = parts.index("Events")
        idx && idx > 0 ? parts[idx - 1] : parts.first
      end

      def extract_occurred_at(event)
        event.respond_to?(:occurred_at) ? event.occurred_at : nil
      end

      def extract_payload(event)
        params = event.class.instance_method(:initialize).parameters
        params.filter_map { |_, name|
          next if name.nil? || name == :occurred_at
          [name.to_s, event.respond_to?(name) ? event.send(name).to_s : "?"]
        }.to_h
      rescue
        {}
      end
    end
  end
end
