require "time"

module Hecks
  module Runtime
    # An emitted domain event. `correlation` (saga head -> value) is runtime bookkeeping
    # and deliberately absent from `to_h`.
    Event = Struct.new(:name, :aggregate, :id, :payload, :occurred_at, :correlation, keyword_init: true) do
      # The one place the runtime reads the wall clock, so every event is stamped the same way.
      #
      # @return [String] the current UTC time as ISO 8601
      def self.stamp = Time.now.utc.iso8601

      # Freezes the event deep, payload and correlation included.
      #
      # @return [void]
      def emit!
        Freezer.deep(payload)
        Freezer.deep(correlation)
        freeze
      end

      def to_h
        {
          name:        name,
          aggregate:   aggregate,
          id:          id,
          payload:     payload,
          occurred_at: occurred_at
        }
      end

      def to_s
        "#{name}(#{aggregate}##{id}) #{payload.inspect}"
      end

      def inspect = "#<Event #{self}>"
    end
  end
end
