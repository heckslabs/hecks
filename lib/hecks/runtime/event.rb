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
      # Freezes the event deep, so nothing about it can change after it happens.
      #
      # An emitted event is a record of something that happened, and a
      # mutable audit trail is not one. The payload — the domain fact the
      # event carries — is frozen through on emission: freezing the Hash
      # alone would leave every value in it editable in place, which is
      # the shape all four previous freezing bugs had.
      #
      # The whole event, not just its payload. Correlation is set at
      # construction rather than merged in here by `Dispatcher#dispatch`
      # after the event already exists, because it is part of the
      # transaction and known from `dispatch`'s own argument before
      # anything is emitted — that is what keeps an event immutable once
      # it exists.
      #
      # The log stays appendable: new events are still recorded. It is
      # each event that stops changing once it exists.
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
