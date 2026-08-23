require_relative "word_gate"
module Hecksagain
  module Bluebook
    module DSL
      class ProcessManagerBuilder
        GRAMMAR_CONTEXT = "ProcessManager"

        class InvalidProcessManager < StandardError; end

        include WordGate

        def initialize(name)
          @name     = name
          @handlers = []
        end

        # `correlates_by`/`starts_on`/`ends_on` — item #13's full
        # metaprogrammed dispatch, slice 1 (whole-project table-
        # unification survey): each a bare, kind-driven coerce-and-
        # assign with nothing else, now executed by `GenericDispatch`.

        # ONE STATE-MACHINE VOCABULARY (S7, ADR 0025 — "events and
        # reactions"): the SAME word `Lifecycle#transition` already
        # carries, one level over — `transition "AccountDebited" =>
        # "awaiting_credit", from: "requested" do ... end` replaces `on
        # "AccountDebited", transition: { "requested" => "awaiting_
        # credit" } do ... end`. Same bare rocket-pair argument shape
        # (not a NAMED `transition:` kwarg wrapping a second Hash), same
        # `from:` — including the array form Lifecycle's own commands
        # could already take and a process manager's own events could
        # not — and the states a procedure runs on are DERIVED from the
        # transitions that name them, the same way `Behaviour::Lifecycle
        # #states` already derives an aggregate's ; `state "x"` lines
        # duplicated exactly what the transition list already said,
        # and could drift from it (`validate!`'s own "undeclared state"
        # check existed only because they could).
        #
        # `starts_on`/`ends_on` are NOT unified into this — verified
        # against the real corpus rather than assumed: Settlement's own
        # `ends_on "TransferSettled"` names an event NONE of its own
        # transitions ever handle (`Transfer.Settle`'s own emission, a
        # full step downstream of the transition that dispatches it),
        # so "the terminal state's own event" is not a fact the
        # transition graph carries — deriving it would either be wrong
        # for this exact corpus member or need a second new word to
        # cover the case, which is not less vocabulary than keeping the
        # one that already says it correctly.
        #
        # EXPANDS IMMEDIATELY, unlike `Lifecycle#transition` (which
        # defers to `Behaviour::Lifecycle#expand`, called at emission
        # time) — `ProcessManager`'s own IR constructor takes `states:`/
        # `handlers:` exactly as it always has, so the runtime
        # (`Behaviour::ProcessManager`, `SagaInterpreter`, saga
        # persistence/rehydration) needs no change at all: what changed
        # is how the DECLARATION reaches that same shape, not the shape
        # a real run ever sees or persists.
        # RENAMED FROM `transition` — item #13's full metaprogrammed
        # dispatch (slice 4c). Not bootstrap-reachable (checked
        # directly — no core/attached chapter declares a ProcessManager
        # of its own).
        def transition_impl(mapping, &block)
          mapping = mapping.dup
          from    = mapping.delete(:from)

          # ALWAYS REQUIRED, unlike `Lifecycle#transition`'s own `from:`
          # — an aggregate's unconstrained transition is admitted from
          # ANY current state (`Behaviour::Lifecycle#applies_from?`
          # returns true for a nil `from`), a reading `SagaInterpreter#
          # advance_saga`'s own admission check does not share: it tests
          # `instance[:state] == handler.from_state` by plain equality,
          # nothing softer. Leaving that check unchanged (this slice's
          # own scope decision — see the class-level comment on why the
          # runtime stays untouched) means an unconstrained PM
          # transition would build cleanly and then match no instance
          # ever, silently — refused here instead, at the one point that
          # can still see the mistake.
          if from.nil?
            raise InvalidProcessManager,
                  "#{@name}'s transition #{mapping.inspect} names no from: — a process manager's own " \
                  "admission checks a saga instance's CURRENT state exactly, so a transition with no " \
                  "from: would match no instance ever, silently"
          end

          handler = HandlerBuilder.new
          handler.instance_eval(&block) if block

          mapping.each do |event_type, target|
            state_transition = StateTransition.new(target: target, from: from)
            expand(event_type.to_s, state_transition, handler.dispatches).each { |row| @handlers << row }
          end
        end

        def build
          validate!

          ProcessManager.new(
            name:          @name,
            correlates_by: @correlates_by,
            starts_on:     @starts_on,
            ends_on:       @ends_on,
            states:        derived_states,
            handlers:      @handlers
          )
        end

        def self.build(name, &block)
          builder = new(name)
          builder.instance_eval(&block) if block
          builder.build
        end

        private

        # ONE DECLARED TRANSITION IS SEVERAL ROWS when `from` names more
        # than one source state — `Behaviour::Lifecycle#expand`'s own
        # comment, the identical fan-out, one level over: a
        # `ProcessManagerHandler` only ever carries a single `from_state`,
        # so a `from: [...]` transition mints one row per source, each
        # carrying the SAME dispatches.
        def expand(event_type, transition, dispatches)
          sources = transition.from.nil? ? [nil] : Array(transition.from)

          sources.map do |source|
            ProcessManagerHandler.new(
              event_type: event_type,
              from_state: source.to_s,
              to_state:   transition.target,
              dispatches: dispatches
            )
          end
        end

        # DERIVED, not declared (S7) — every state this procedure ever
        # runs on is already named by some transition's own `from_state`
        # or `to_state`; a state nothing transitions into or out of is
        # not a state this procedure has, the same reading
        # `Behaviour::Lifecycle#states` already gives an aggregate's own
        # field. FIRST-SEEN ORDER, walking declaration order — `begin_
        # saga`'s own `pm.states.first` is what a fresh instance starts
        # in, so the order has to survive the derivation, not just the
        # membership.
        def derived_states
          @handlers.flat_map { |h| [h.from_state, h.to_state] }.reject(&:empty?).uniq
        end

        def validate!
          raise InvalidProcessManager, "#{@name} declares no correlates_by — " \
                                       "nothing would tie its events to one instance" unless @correlates_by

          # THE FIELD, NAMED — never the value object that carries it. A bare
          # `correlates_by :end_to_end` reads whatever the payload holds under
          # that key AS the correlation key, and what a non-scalar key even
          # is stays open (the object itself? its serialised text?).
          # Requiring the dotted spelling —
          # `:"end_to_end.value"` — makes every correlates_by name a scalar
          # by construction, the same discipline `identified_by` already
          # holds a head to. This is a syntactic check, not a type check: it
          # does not know or care whether the field IS a value object, only
          # that the declaration cannot leave that question open.
          raise InvalidProcessManager, "#{@name} correlates_by #{@correlates_by.inspect}, which names a whole " \
                                       "field rather than one of its scalars — say which one, e.g. " \
                                       "#{@correlates_by}.value" unless @correlates_by.to_s.include?(".")

          raise InvalidProcessManager, "#{@name} declares no starts_on — " \
                                       "nothing would ever begin it" if @starts_on.to_s.empty?

          raise InvalidProcessManager, "#{@name} declares no transitions — " \
                                       "it would start and then ignore every event" if @handlers.empty?
        end

        class HandlerBuilder
          GRAMMAR_CONTEXT = "Handler"

          attr_reader :dispatches

          include WordGate

          def initialize = @dispatches = []

          # THE COMMAND ITSELF (ADR 0025, "events and reactions" — command
          # references become first-class), same shape and same reasons
          # as `PolicyBuilder#trigger`'s own header — bare constant live,
          # quoted text only under shadow-parsing (S0a's bridge; frozen
          # era text still writes `dispatch "Banking::Account.Debit"`).
          #
          # RENAMED FROM `dispatch` — item #13's full metaprogrammed
          # dispatch (slice 4), same reasoning as trigger_impl above.
          def dispatch_impl(command_ref, with: nil)
            if command_ref.is_a?(::String) && !MetaValidator.shadow_parsing?
              raise InvalidProcessManager,
                    "dispatch #{command_ref.inspect} is quoted text — give the bare command constant " \
                    "instead, e.g. dispatch Account::Debit"
            end

            DispatchSpec.new(
              command_name: Naming.command_ref(command_ref),
              with_spec:    (with || {}).to_a
            ).tap do |dispatch|
              dispatch.instance_variable_set(:@projection_declared, !with.nil?)
              @dispatches << dispatch
            end
          end
        end
      end
    end
  end
end
