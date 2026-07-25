# Event — something the domain announced after a command landed.
#
# An event is a FACT: it names what happened, which aggregate instance it
# happened to, and the payload that caused it. It is emitted after the
# mutations are applied and after the instance is saved, so an event is never
# observed for a state that was not persisted.
#
#   Event.new(name: "PizzaPurchased", aggregate: "Pizzas::Pizza", id: "pizza-1a2b")
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
