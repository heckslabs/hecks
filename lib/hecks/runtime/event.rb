require "time"

module Hecks
  module Runtime
    # `correlation` is not on the wire — `to_h` below deliberately omits it,
    # the same as `bin/run`'s own event projection does. It is runtime
    # bookkeeping stamped by `Dispatcher#dispatch` when a saga leg's own
    # dispatch causes this event (see `SagaInterpreter#deliver_saga_dispatch`
    # and `#saga_correlation`) : a Hash of `correlation_head` -> correlation
    # value, so an event caused by one saga cannot be misread by an unrelated
    # one correlating on a different field. Absent for any event no saga
    # dispatch caused, which is most of them.
    Event = Struct.new(:name, :aggregate, :id, :payload, :occurred_at, :correlation, keyword_init: true) do
      # An emitted event is a record of something that happened, and a
      # mutable audit trail is not one. The payload — the domain fact the
      # event carries — is frozen through on emission: freezing the Hash
      # alone would leave every value in it editable in place, which is
      # the shape all four previous freezing bugs had.
      #
      # Freezes the payload, the correlation, and the event itself, so it can be logged.
      #
      # The whole event, not just its payload. Correlation is set at
      # construction, not merged onto an already-emitted event by
      # `Dispatcher#dispatch` — merging after the fact is what would keep
      # an event writable after it had happened. Setting it at
      # construction works because correlation is part of the transaction,
      # known from `dispatch`'s own argument before anything is emitted.
      #
      # The log stays appendable: new events are still recorded. It is
      # each event that stops changing once it exists.
      #
      # @return [Hecks::Runtime::Event] this event, frozen
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
