require_relative "../../naming"
require_relative "../value"

module Hecksagain
  module Runtime
    class SagaInterpreter
      # How a saga decides WHICH CONVERSATION an event belongs to — three
      # tiers, each one a lesson.
      module Correlation
        private

        # A DOTTED PATH NAMES THE SCALAR FIELD, rather than asking a value object
        # to stand in for one. `correlates_by :end_to_end` would key a saga on
        # the whole ExternalTransfer::EndToEndReference — and what a non-scalar
        # correlation key even IS is representation-dependent (the object
        # itself? its serialised text?). `:"end_to_end.value"` reads the one
        # field with a single unambiguous rendering.
        def saga_correlation(pm, event)
          path  = pm.correlates_by.to_s.split(".")
          # A LATER EVENT MAY ALREADY HOLD THE SCALAR. `reference.value` digs a
          # value object's field out of a FRESH declaration (TransferRequested's
          # `reference` IS a TransferReference) — but a downstream event this
          # same value was smuggled through as a passthrough argument
          # (AccountDebited's `reference:`, resolved by `dispatch_args` to the
          # bare correlation string) carries it as a scalar already, with
          # nothing left to dig. `"xfer-1".respond_to?(:[])` is true — String
          # has its OWN `[]` (substring indexing) — so checking for keyed
          # lookup explicitly, rather than "responds to `[]` at all", is what
          # stops the second segment from being read as a symbol index into a
          # string that has already arrived.
          value = path.reduce(event.payload) do |held, segment|
            held.is_a?(Hash) || held.is_a?(Value) ? held[segment.to_sym] : held
          end
          return value unless value.to_s.empty?

          # THE STAMP — `deliver_saga_dispatch` marks its own event before this
          # saga's next step ever asks, for a leg whose command declares
          # NEITHER the correlation field itself nor the emitting aggregate's
          # own reference key (the two tiers above). command_interpreter/
          # argument_gate.rb names the old payload-only lookup "the weakest
          # part of the gate" : a correlation key arriving on a command only
          # because `correlation_keys` widens the undeclared-argument
          # allow-list domain-wide. This is the additive fix — a leg that
          # carries nothing correlation-shaped at all still correlates,
          # because the saga that dispatched it already knows the answer.
          # Keyed by `correlation_head`
          # rather than a bare scalar so an event stamped by one saga cannot be
          # misread by an unrelated one correlating on a different field.
          stamped = event.correlation && event.correlation[pm.correlation_head.to_s]
          return stamped unless stamped.nil? || stamped.to_s.empty?

          # A SELF-REFERENCING LEG carries the correlation forward under ITS
          # OWN reference key ("wire", "transfer") — the address
          # `hydrate`'s "acts on an existing aggregate" branch demands when the
          # aggregate's declared identity path is not what a `with:` binding
          # supplied — not under whatever the correlates_by field happens to be
          # called ("reference.value"). That key is constant across every
          # self-referencing command on the tracked aggregate regardless of
          # which field first carried the value in, and it never collides with
          # an unrelated aggregate's own event: `Account.Debit` addresses by
          # its OWN declared identity path ("number"), never by
          # `reference_key`, so nothing is found there for an event that does
          # not belong to this saga.
          own_key = Naming.reference_key(event.aggregate).to_sym
          event.payload[own_key]
        end
      end
    end
  end
end
