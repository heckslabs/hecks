require "time"

module Hecksagain
  module Runtime
    Event = Struct.new(:name, :aggregate, :id, :payload, :occurred_at, keyword_init: true) do
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
