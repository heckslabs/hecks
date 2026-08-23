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

          # A SELF-REFERENCING LEG carries the correlation forward under its
          # own emitting record's identity — `event.id`, not a field dug back
          # out of the payload. This used to read `event.payload[own_key]`
          # (`own_key` the aggregate's own reference-key convention, "wire",
          # "transfer"), which only ever held a value because LEGACY dispatch
          # left the self-addressing key riding along in the payload
          # unfiltered. Routing separated from payload (`to:`/`with:`, the
          # facade's own `Handle#run` always uses it) closed exactly that
          # leak — correctly, since an addressing key is not a fact the
          # payload should carry — which left this tier reading an empty
          # Hash for any self-referencing leg with no OTHER declared
          # attributes (`OnboardingCase.Clear`, `.Decline` — no `attribute`
          # lines at all): the saga silently stopped advancing, forever, for
          # exactly the leg this tier exists to correlate.
          #
          # `event.id` says the identical thing this tier always meant —
          # "the record that just emitted this event, by its own identity" —
          # and unlike a payload dig it is populated by the record itself,
          # not by which dispatch convention the caller happened to use.
          #
          # GATED, still — a manually-dispatched command on a wholly
          # UNRELATED aggregate can share an event NAME this pm happens to
          # handle (`Drawer.Take` also emits "Taken", the same name a
          # SAGA-DISPATCHED leg uses) with nothing this saga should read as
          # its own conversation. What makes a leg genuinely
          # self-referencing — the one fact worth trusting `event.id`
          # for — is that `correlates_by`'s own head field IS this event's
          # OWN aggregate's declared identity, not merely a same-shaped
          # name: `OnboardingCase.identity_heads` really does include
          # `:reference`, `correlates_by :"reference.value"`'s own head ;
          # `Drawer.identity_heads` is `[:number]`, nowhere close.
          self_identified?(pm, event) ? event.id : nil
        end

        def self_identified?(pm, event)
          domain, bare_name = event.aggregate.to_s.split("::", 2)
          return false unless bare_name

          construct = @registry.bluebook(domain)&.aggregate(bare_name)
          return false unless construct

          construct.identity_heads.map(&:to_s).include?(pm.correlation_head.to_s)
        end
      end
    end
  end
end
