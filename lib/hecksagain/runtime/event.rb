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
      # AN EMITTED EVENT IS A RECORD OF SOMETHING THAT HAPPENED, and a
      # mutable audit trail is not one. The PAYLOAD — the domain fact the
      # event carries — is frozen THROUGH on emission: freezing the Hash
      # alone would leave every value in it editable in place, which is
      # the shape all four previous freezing bugs had.
      #
      # THE WHOLE EVENT, not just its payload. Correlation used to be
      # merged onto already-emitted events by `Dispatcher#dispatch`, which
      # is what kept an event writable after it had happened; it is set at
      # construction now, because it is part of the transaction and known
      # from `dispatch`'s own argument before anything is emitted.
      #
      # The LOG stays appendable: new events are still recorded. It is
      # each event that stops changing once it exists.
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
