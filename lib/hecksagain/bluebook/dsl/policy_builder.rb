require_relative "word_gate"
module Hecksagain
  module Bluebook
    module DSL
      class PolicyBuilder
        GRAMMAR_CONTEXT = "Policy"

        include WordGate

        def initialize(name)
          @name = name
        end

        # `on` — item #13's full metaprogrammed dispatch, slice 1
        # (whole-project table-unification survey): a bare, kind-driven
        # coerce-and-assign, now executed by `GenericDispatch`.

        # `with:` — WHAT THE TRIGGER IS GIVEN, when the event's own shape
        # is not it. Omitted, the whole event payload forwards verbatim,
        # which is what every policy did before this existed.
        #
        # Same `key => value` shape a saga's own `dispatch ..., with:`
        # takes, and read the same way at runtime: a Symbol names a field
        # on the triggering event, anything else is a literal the policy
        # supplies itself. The reason it exists is the reason a saga's
        # does — a reaction crosses an aggregate boundary, and the event
        # on one side is under no obligation to be shaped like the
        # command on the other. Without it the target has to DECLARE
        # every field the event happens to carry, whether it reads them
        # or not.
        # THE COMMAND ITSELF, NOT ITS NAME (ADR 0025, "events and
        # reactions" — command references become first-class): `trigger
        # Account::Debit`, a bare constant `ConstShim` resolves the same
        # way `reference_to Account` always has, not a quoted verb string.
        # Collapses the qualified/unqualified split this word and a
        # saga's own `dispatch` used to disagree about — see
        # `Naming.command_ref`'s own header for how the `::`/`.` rewrite
        # works, and `SagaInterpreter#qualified` for why an unqualified
        # form has always been enough (same-domain is the fallback, so
        # `Account::Debit` and `Banking::Account::Debit` mean the same
        # thing here).
        #
        # LEGACY UNDER SHADOW-PARSING (S0a's own bridge) — frozen era
        # text still writes the quoted form.
        #
        # RENAMED FROM `trigger` — item #13's full metaprogrammed
        # dispatch (slice 4), same reasoning as has_many_impl above: not
        # bootstrap-reachable, reached through calls: with no fallback
        # needed.
        def trigger_impl(command_ref, with: nil)
          if command_ref.is_a?(::String) && !MetaValidator.shadow_parsing?
            raise Malformed,
                  "#{@name}'s trigger #{command_ref.inspect} is quoted text — give the bare command " \
                  "constant instead, e.g. trigger Account::Debit"
          end

          @trigger_command = Naming.command_ref(command_ref)
          @with_spec = (with || {}).to_a
        end

        # `across` — item #13's full metaprogrammed dispatch, slice 1:
        # same shape as `on`, above.

        # THE GUARD — same extraction CommandBuilder#given/#ensures already
        # use (Ports::Extraction reads the block's SOURCE ; the block itself
        # is never called, here or at runtime — Runtime::PolicyInterpreter
        # evaluates the extracted text through the same
        # Bluebook::Expression::Evaluator a command's own given/ensures run
        # through). No description argument the way given/ensures each
        # carry one : a given's description becomes a GivenNotMet message,
        # and a where that does not hold refuses nothing — it just means
        # this policy does not apply to this event, exactly like an
        # `event_qualifier` miss, which carries no message either.
        #
        # Evaluated against the triggering EVENT's OWN PAYLOAD, not a
        # stored record — a policy reacts to what just happened, and has no
        # aggregate instance of its own to read state from.
        def where(&predicate)
          canonical = Ports::Extraction.canonical(predicate)

          if canonical.to_s.empty?
            raise Malformed,
                  "#{@name}'s where did not survive extraction — its source " \
                  "could not be read, so no other runtime could ever evaluate it"
          end

          @where = canonical
        end

        # THE FAN-OUT SOURCE — a query verb, "Aggregate.query_name" or
        # "Domain::Aggregate.query_name", the same qualified-or-not shape a
        # saga's own `dispatch` command name already takes
        # (SagaInterpreter#qualified). Runtime::PolicyInterpreter runs the
        # named query against the triggering event's own payload and fires
        # `trigger` once per row, instead of once for the event.
        # `for_each` — item #13's full metaprogrammed dispatch, slice 1:
        # same shape as `on`, above.

        def build
          Policy.new(
            name:            @name,
            on_event:        @on_event,
            trigger_command: @trigger_command,
            target_domain:   @target_domain,
            where:           @where,
            for_each:        @for_each,
            with_spec:       @with_spec || []
          )
        end

        def self.build(name, &block)
          builder = new(name)
          builder.instance_eval(&block) if block
          builder.build
        end
      end
    end
  end
end
