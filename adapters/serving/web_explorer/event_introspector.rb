# Hecks::WebExplorer::EventIntrospector
#
# Reads events from one or more EventBus instances and provides
# filtering, sorting, and type discovery for the web explorer
# event log browser page.
#
#   bus = Hecks::EventBus.new
#   introspector = EventIntrospector.new([bus])
#   introspector.all_entries                          # => [{type:, aggregate:, ...}]
#   introspector.all_entries(type_filter: "CreatedPizza")
#   introspector.event_types                          # => ["CreatedPizza", "PlacedOrder"]
#   introspector.aggregate_types                      # => ["Pizza", "Order"]
#
module Hecks
  module WebExplorer
    # Hecks::WebExplorer::EventIntrospector
    #
    # Reads events from EventBus instances and provides filtering, sorting, and type discovery for the web explorer.
    #
    class EventIntrospector
      def initialize(event_buses)
        @event_buses = Array(event_buses)
      end

      # Returns all events as hashes, newest first.
      # Supports optional type and aggregate filters.
      #
      # @param type_filter [String, nil] exact event type name to match
      # @param aggregate_filter [String, nil] aggregate name to match
      # @return [Array<Hash>] event entries with :type, :aggregate, :occurred_at, :payload
      def all_entries(type_filter: nil, aggregate_filter: nil)
        entries = raw_events.map { |e| to_entry(e) }
        entries = entries.select { |e| e[:type] == type_filter } if type_filter && !type_filter.empty?
        entries = entries.select { |e| e[:aggregate] == aggregate_filter } if aggregate_filter && !aggregate_filter.empty?
        entries.sort_by { |e| e[:occurred_at] || Time.at(0) }.reverse
      end

      # Returns distinct event type names from the log.
      #
      # @return [Array<String>] sorted unique event type names
      def event_types
        raw_events.map { |e| short_name(e) }.uniq.sort
      end

      # Returns distinct aggregate names inferred from event class nesting.
      #
      # @return [Array<String>] sorted unique aggregate names
      def aggregate_types
        raw_events.map { |e| infer_aggregate(e) }.compact.uniq.sort
      end

      private

      def raw_events
        @event_buses.flat_map(&:events)
      end

      def to_entry(event)
        {
          type: short_name(event),
          aggregate: infer_aggregate(event),
          occurred_at: event.respond_to?(:occurred_at) ? event.occurred_at : nil,
          payload: extract_payload(event)
        }
      end

      def short_name(event)
        Hecks::Utils.const_short_name(event)
      end

      # Infer aggregate from class nesting: PizzasDomain::Pizza::Events::CreatedPizza
      def infer_aggregate(event)
        parts = event.class.name.to_s.split("::")
        events_idx = parts.index("Events")
        events_idx && events_idx > 0 ? parts[events_idx - 1] : nil
      end

      def extract_payload(event)
        ivars = event.instance_variables - [:@occurred_at]
        ivars.each_with_object({}) do |ivar, h|
          key = ivar.to_s.delete_prefix("@")
          h[key] = event.instance_variable_get(ivar).to_s
        end
      end
    end
  end
end
