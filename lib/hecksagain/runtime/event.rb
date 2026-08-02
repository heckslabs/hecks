require "time"

module Hecksagain
  module Runtime
    # `correlation` is NOT on the wire — `to_h` below deliberately omits it,
    # the same as `bin/run`'s own event projection does. It is runtime
    # bookkeeping stamped by `Dispatcher#dispatch` when a saga leg's own
    # dispatch causes this event (see `SagaInterpreter#deliver_saga_dispatch`
    # and `#saga_correlation`) : a Hash of `correlation_head` -> correlation
    # value, so an event caused by one saga cannot be misread by an unrelated
    # one correlating on a different field. Absent for any event no saga
    # dispatch caused, which is most of them.
    Event = Struct.new(:name, :aggregate, :id, :payload, :occurred_at, :correlation, keyword_init: true) do
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
