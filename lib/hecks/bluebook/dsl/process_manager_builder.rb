require_relative "word_gate"
module Hecks
  module Bluebook
    module DSL
      # Parses a `process_manager "Name" do ... end` block into a
      # `ProcessManager` — its own `starts_on`/`ends_on` events, what
      # correlates its instances (`correlates_by`), and the `transition`-
      # declared state machine whose `dispatch`es (each optionally paired
      # with its own per-dispatch `compensates`) become its handlers. States
      # are derived from the transitions rather than declared separately
      # (S7, ADR 0025).
      class ProcessManagerBuilder
        GRAMMAR_CONTEXT = "ProcessManager".freeze

        class InvalidProcessManager < StandardError; end

        include WordGate

        # @param name [String] the process manager's name, as written after `process_manager`
        def initialize(name)
          @name     = name
          @handlers = []
        end

        # Names the event that begins a new instance of this saga.
        #
        # `starts_on Transfer::TransferRequested` — bare constant
        # accepted (ADR 0025, S6 — "events first-class"), resolved
        # through `ConstShim` the same way `on_impl`/`transition_impl`
        # resolve an event reference — but through `Naming.
        # event_name_ref`, not `Naming.event_ref` (that method's own
        # header has the full account: `SagaInterpreter` matches
        # `pm.starts_on`/`pm.ends_on` against a bare `event.name`, never
        # a "." qualified one). A plain String still passes through
        # unchanged, both for `shadow_parse` and for any corpus site a
        # future pass hasn't migrated yet.
        #
        # @param event_ref [String, Symbol, Module] the event, a bare constant or a plain String
        # @return [String] the bare event name, demodulised
        def starts_on_impl(event_ref)
          @starts_on = Naming.event_name_ref(event_ref)
        end

        # Names the event this saga treats as its own last one.
        #
        # `ends_on` — same reasoning as `starts_on_impl`, above.
        #
        # @param event_ref [String, Symbol, Module] the event, a bare constant or a plain String
        # @return [String] the bare event name, demodulised
        def ends_on_impl(event_ref)
          @ends_on = Naming.event_name_ref(event_ref)
        end

        # `correlates_by` — item #13's full metaprogrammed dispatch,
        # slice 1 (whole-project table-unification survey): a bare,
        # kind-driven coerce-and-assign with nothing else, executed by
        # `GenericDispatch`.
        #
        # `starts_on`/`ends_on` are hand-written rather than table-driven
        # the same way: ADR 0025 S6 gave each a second, `kind: "constant"`
        # ArgumentSeed row (`starts_on Transfer::TransferRequested`), and
        # `GenericDispatch::COERCE_BY_KIND` only knows `"text"`/
        # `"symbol"`, while `shape_for` refuses to pick a `single_fill`
        # shape at all once two Argument rows share a `fills:` target
        # (`arguments.size == 1` below) — so both words are `calls:`-routed
        # like `transition` already is.

        # One state-machine vocabulary (S7, ADR 0025 — "events and
        # reactions"): the same word `Lifecycle#transition` already
        # carries, one level over — `transition "AccountDebited" =>
        # "awaiting_credit", from: "requested" do ... end` replaces `on
        # "AccountDebited", transition: { "requested" => "awaiting_
        # credit" } do ... end`. Same bare rocket-pair argument shape
        # (not a named `transition:` kwarg wrapping a second Hash), same
        # `from:` — including the array form Lifecycle's own commands
        # could already take and a process manager's own events could
        # not — and the states a procedure runs on are derived from the
        # transitions that name them, the same way `Behaviour::Lifecycle
        # #states` already derives an aggregate's ; `state "x"` lines
        # duplicated exactly what the transition list already said,
        # and could drift from it (`validate!`'s own "undeclared state"
        # check existed only because they could).
        #
        # `starts_on`/`ends_on` are not unified into this — verified
        # against the real corpus rather than assumed: Settlement's own
        # `ends_on "TransferSettled"` names an event none of its own
        # transitions ever handle (`Transfer.Settle`'s own emission, a
        # full step downstream of the transition that dispatches it),
        # so "the terminal state's own event" is not a fact the
        # transition graph carries — deriving it would either be wrong
        # for this exact corpus member or need a second new word to
        # cover the case, which is not less vocabulary than keeping the
        # one that already says it correctly.
        #
        # Expands immediately, unlike `Lifecycle#transition` (which
        # defers to `Behaviour::Lifecycle#expand`, called at emission
        # time) — `ProcessManager`'s own IR constructor takes `states:`/
        # `handlers:` exactly as it always has, so the runtime
        # (`Behaviour::ProcessManager`, `SagaInterpreter`, saga
        # persistence/rehydration) needs no change at all: what changed
        # is how the declaration reaches that same shape, not the shape
        # a real run ever sees or persists.
        # Records handler rows for one state-machine transition, one per event named in `mapping`.
        #
        # Answers the `transition` word through the table's `calls:`
        # column — item #13's full metaprogrammed
        # dispatch (slice 4c). Not bootstrap-reachable (checked
        # directly — no core/attached chapter declares a ProcessManager
        # of its own).
        #
        # @param mapping [Hash{Symbol, String, Module => String}] one or more event references
        #   mapped to the target state; the `:from` key holds the required source state, or
        #   Array of states, and is required
        # @yield an optional body opening `dispatch` calls, evaluated against a `HandlerBuilder`
        # @return [void]
        # @raise [Bluebook::DSL::ProcessManagerBuilder::InvalidProcessManager] if `mapping`
        #   names no `from:`
        def transition_impl(mapping, &block)
          mapping = mapping.dup
          from    = mapping.delete(:from)

          # Always required, unlike `Lifecycle#transition`'s own `from:`
          # — an aggregate's unconstrained transition is admitted from
          # any current state (`Behaviour::Lifecycle#applies_from?`
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
            # Bare constant accepted (ADR 0025, S6 — "events first-
            # class"), `transition Account::AccountDebited => "state"` —
            # `Naming.event_name_ref`, not the dotted `Naming.event_ref`
            # transform `PolicyBuilder#on_impl` uses (that method's own
            # header has the full account, found live wiring a real
            # migrated corpus site into `bin/model_check` for the first
            # time: `SagaInterpreter#advance_saga` matches `handler.
            # event_type` against a bare `event.name`, never a "."
            # qualified one — a policy's own cross-aggregate match
            # works differently, splitting the qualifier apart from the
            # name rather than comparing the whole string). Writing the
            # qualifier is still worth it (the same provenance `trigger
            # Account::Debit` gives a reader) — `event_name_ref` keeps
            # only the final segment, so `Account::AccountDebited` and a
            # bare `AccountDebited` store identically. A plain String
            # still passes through unchanged, both for `shadow_parse`
            # and for every corpus site this pass didn't migrate.
            state_transition = StateTransition.new(target: target, from: from)
            expand(Naming.event_name_ref(event_type), state_transition, handler.dispatches).each { |row| @handlers << row }
          end
        end

        # Assembles the declared events, correlation key and derived states into a `ProcessManager`.
        #
        # @return [Bluebook::ProcessManager] the built saga definition
        # @raise [Bluebook::DSL::ProcessManagerBuilder::InvalidProcessManager] if `correlates_by`
        #   or `starts_on` is undeclared, `correlates_by` names a whole field rather than one
        #   scalar, no transitions are declared, or two transitions collide on (event, state)
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

        # Evaluates a `process_manager` block against a fresh builder and returns the built saga.
        #
        # @param name [String] the process manager's name
        # @yield the process manager body, evaluated with the builder as `self`; may be omitted
        # @return [Bluebook::ProcessManager] the built saga definition
        # @raise [Bluebook::DSL::ProcessManagerBuilder::InvalidProcessManager] if the body fails
        #   `validate!`
        def self.build(name, &block)
          builder = new(name)
          builder.instance_eval(&block) if block
          builder.build
        end

        private

        # One declared transition is several rows when `from` names more
        # than one source state — `Behaviour::Lifecycle#expand`'s own
        # comment, the identical fan-out, one level over: a
        # `ProcessManagerHandler` only ever carries a single `from_state`,
        # so a `from: [...]` transition mints one row per source, each
        # carrying the same dispatches.
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

        # Derived, not declared (S7) — every state this procedure ever
        # runs on is already named by some transition's own `from_state`
        # or `to_state`; a state nothing transitions into or out of is
        # not a state this procedure has, the same reading
        # `Behaviour::Lifecycle#states` already gives an aggregate's own
        # field. First-seen order, walking declaration order — `begin_
        # saga`'s own `pm.states.first` is what a fresh instance starts
        # in, so the order has to survive the derivation, not just the
        # membership.
        def derived_states
          @handlers.flat_map { |h| [h.from_state, h.to_state] }.reject(&:empty?).uniq
        end

        def validate!
          unless @correlates_by
            raise InvalidProcessManager, "#{@name} declares no correlates_by — " \
                                         "nothing would tie its events to one instance"
          end

          # **The field, named** — never the value object that carries it. A bare
          # `correlates_by :end_to_end` reads whatever the payload holds under
          # that key as the correlation key, and what a non-scalar key even
          # is stays open (the object itself? its serialised text?).
          # Requiring the dotted spelling —
          # `:"end_to_end.value"` — makes every correlates_by name a scalar
          # by construction, the same discipline `identified_by` already
          # holds a head to. This is a syntactic check, not a type check: it
          # does not know or care whether the field is a value object, only
          # that the declaration cannot leave that question open.
          unless @correlates_by.to_s.include?(".")
            raise InvalidProcessManager, "#{@name} correlates_by #{@correlates_by.inspect}, which names a whole " \
                                         "field rather than one of its scalars — say which one, e.g. " \
                                         "#{@correlates_by}.value"
          end

          if @starts_on.to_s.empty?
            raise InvalidProcessManager, "#{@name} declares no starts_on — " \
                                         "nothing would ever begin it"
          end

          if @handlers.empty?
            raise InvalidProcessManager, "#{@name} declares no transitions — " \
                                         "it would start and then ignore every event"
          end

          refuse_ambiguous_legs!
        end

        # C10.3 — a leg is selected by (event, current state), so two
        # legs answering the same event from the same state would leave
        # the runtime to pick by declaration order, silently. Refused
        # here, where the declaration can still be read whole. (`from:
        # [...]` fan-out counts: `transition E => "a", from: ["x", "y"]`
        # and `transition E => "b", from: "y"` collide on ("E", "y").)
        def refuse_ambiguous_legs!
          return if MetaValidator.shadow_parsing? # frozen era text is history

          seen = {}
          @handlers.each do |handler|
            key = [handler.event_type, handler.from_state]
            if (earlier = seen[key])
              raise InvalidProcessManager,
                    "#{@name} declares two transitions on #{handler.event_type.inspect} from " \
                    "#{handler.from_state.inspect} (=> #{earlier.to_state.inspect} and => " \
                    "#{handler.to_state.inspect}) — a leg is selected by (event, current state), so " \
                    "only one may answer"
            end
            seen[key] = handler
          end
        end

        # The body of one `transition ... do ... end` block — collects the
        # `dispatch` calls (each optionally opening its own `compensates`
        # via the nested `DispatchBuilder`) that fire when this transition
        # is taken.
        class HandlerBuilder
          GRAMMAR_CONTEXT = "Handler".freeze

          attr_reader :dispatches

          include WordGate

          # Starts with no dispatches recorded.
          def initialize = @dispatches = []

          # Records a command this transition dispatches, with an optional per-dispatch
          # compensation.
          #
          # The command itself (ADR 0025, "events and reactions" — command
          # references become first-class), same shape and same reasons
          # as `PolicyBuilder#trigger`'s own header — bare constant live,
          # quoted text only under shadow-parsing (S0a's bridge; frozen
          # era text still writes `dispatch "Banking::Account.Debit"`).
          #
          # Answers the `dispatch` word through the table's `calls:`
          # column — item #13's full metaprogrammed
          # dispatch (slice 4), same reasoning as `trigger_impl` above.
          #
          # An optional block opens `compensates` on this dispatch
          # specifically — per-dispatch saga compensation, replacing a
          # hand-written list at the saga's own `on :refused` leg. Real,
          # live bug this closes: `examples/banking/bluebook/transfers_
          # and_payments.bluebook`'s own `Settlement` saga wrote a
          # compensating reversal by hand that depended on an event only
          # fired if someone dispatched it manually — "the reversal was
          # written and never armed" (that file's own comment). The
          # runtime now tracks which legs actually completed
          # (`SagaInterpreter`'s own `completed_compensations`) and
          # compensates only those, newest first, instead of trusting an
          # author's static list to be complete and correctly ordered.
          #
          # @param command_ref [Module, Symbol, String] the command to dispatch, a bare constant
          #   such as `Account::Debit`, or (only under shadow-parsing) quoted text
          # @param with [Hash{Symbol => Symbol, Object}, nil] projects saga-available data onto
          #   the command's own arguments; a Symbol value names a field, anything else is a
          #   literal; nil forwards nothing extra
          # @yield an optional body opening `compensates`, evaluated against a `DispatchBuilder`
          # @return [Bluebook::DispatchSpec] the recorded dispatch spec
          # @raise [Bluebook::DSL::ProcessManagerBuilder::InvalidProcessManager] if `command_ref`
          #   is quoted text outside shadow-parsing
          def dispatch_impl(command_ref, with: nil, &block)
            if command_ref.is_a?(::String) && !MetaValidator.shadow_parsing?
              raise InvalidProcessManager,
                    "dispatch #{command_ref.inspect} is quoted text — give the bare command constant " \
                    "instead, e.g. dispatch Account::Debit"
            end

            spec = DispatchSpec.new(
              command_name: Naming.command_ref(command_ref),
              with_spec:    (with || {}).to_a
            )
            spec.instance_variable_set(:@projection_declared, !with.nil?)

            if block
              builder = DispatchBuilder.new
              builder.instance_eval(&block)
              # `instance_variable_get`, not a public `compensates_spec`
              # reader — a public one would be a method the grammar
              # never declares, exactly what `spec/syntax_conformance_
              # spec.rb`'s "answers only words the language declares"
              # check exists to catch.
              spec.compensates = builder.instance_variable_get(:@compensates_spec)
            end

            @dispatches << spec
            spec
          end

          # The nested scope `dispatch ... do ... end` opens — one word
          # only (`compensates`), the compensating half of the dispatch it
          # sits inside. Its own `compensates_impl` builds a second
          # `DispatchSpec`, shape-identical to `HandlerBuilder#dispatch_
          # impl`'s own — a compensation takes the exact same two
          # arguments (a bare command constant, an optional `with:`)
          # because it resolves through the identical scope (current
          # event payload, opening event memory, correlation binding)
          # any saga dispatch already does
          # (`SagaInterpreter#dispatch_args`).
          class DispatchBuilder
            GRAMMAR_CONTEXT = "Dispatch".freeze

            include WordGate

            # Records the command that undoes the enclosing dispatch.
            #
            # @param command_ref [Module, Symbol, String] the compensating command, a bare
            #   constant such as `Account::Credit`, or (only under shadow-parsing) quoted text
            # @param with [Hash{Symbol => Symbol, Object}, nil] projects saga-available data onto
            #   the command's own arguments; a Symbol value names a field, anything else is a
            #   literal; nil forwards nothing extra
            # @return [Bluebook::DispatchSpec] the recorded compensating dispatch spec
            # @raise [Bluebook::DSL::ProcessManagerBuilder::InvalidProcessManager] if
            #   `command_ref` is quoted text outside shadow-parsing
            def compensates_impl(command_ref, with: nil)
              if command_ref.is_a?(::String) && !MetaValidator.shadow_parsing?
                raise InvalidProcessManager,
                      "compensates #{command_ref.inspect} is quoted text — give the bare command constant " \
                      "instead, e.g. compensates Account::Credit"
              end

              @compensates_spec = DispatchSpec.new(
                command_name: Naming.command_ref(command_ref),
                with_spec:    (with || {}).to_a
              )
            end
          end
        end
      end
    end
  end
end
