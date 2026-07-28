module Hecksagain
  module Adapters
    class Memory
      attr_reader :aggregate

      def initialize(aggregate:, settings: {}, root: nil)
        @aggregate = aggregate
        @records   = {}
        @events    = []
      end

      def find(id) = @records[id.to_s]
      def all      = @records.values
      def count    = @records.size

      def save(instance)
        @records[instance.id.to_s] = instance
      end

      def record_event(event) = @events << event

      def events = @events
    end
  end
end
