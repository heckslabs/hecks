require_relative "word_gate"
module Hecks
  module Bluebook
    module DSL
      # Parses a `policy "Name" do ... end` block into a `Policy` — a
      # reaction wired at chapter scope: `on` the event it watches, an
      # optional `where` guard evaluated against the event's own payload, an
      # optional `for_each` fan-out query, and the `trigger` command it
      # dispatches (`with:` projecting the event's payload onto the
      # command's own arguments when the two shapes differ).
      class PolicyBuilder
        GRAMMAR_CONTEXT = "Policy".freeze

        include WordGate

        # @param name [String] the policy's own name, as given to `policy "Name" do ... end`
        def initialize(name)
          @name = name
        end

        # Records the event this policy reacts to.
        #
        # `on Account::AccountFrozen` — a bare constant accepted (ADR
        # 0025, S6 — "events first-class"), resolved through `ConstShim`
        # the same way `trigger`/`dispatch` already resolve a command
        # reference (`Naming.event_ref`, that method's own header). Not
        # a required spelling yet, unlike `trigger`'s own quoted-text
        # refusal — see `policy.bluebook`'s own KeywordSeed comment for
        # why: event names aren't 100% migrated across the live corpus
        # the way command references are, so both `on "Account.
        # AccountFrozen"` (quoted) and `on Account::AccountFrozen`
        # (bare) stay admitted until a full migration lands.
        #
        # Reached through `calls: "on_impl"` rather than `GenericDispatch`'s generic single-fill
        # coercion, the same way `trigger_impl` below overrides its own generic default — `on`
        # admits both a bare constant and quoted text, not one single argument kind.
        #
        # @param event_ref [Symbol, String, Module] the event, as a bare constant (a
        #   `ScopedConstant` module `ConstShim` resolves) or quoted text
        # @return [void]
        def on_impl(event_ref)
          @on_event = Naming.event_ref(event_ref)
        end

        # Records the command this policy dispatches and, optionally, how the event's payload
        # projects onto it.
        #
        # `with:` — what the trigger is given, when the event's own shape
        # is not it. Omitted, the whole event payload forwards verbatim.
        #
        # Same `key => value` shape a saga's own `dispatch ..., with:`
        # takes, and read the same way at runtime: a Symbol names a field
        # on the triggering event, anything else is a literal the policy
        # supplies itself. The reason it exists is the reason a saga's
        # does — a reaction crosses an aggregate boundary, and the event
        # on one side is under no obligation to be shaped like the
        # command on the other. Without it the target has to declare
        # every field the event happens to carry, whether it reads them
        # or not.
        # The command itself, not its name (ADR 0025, "events and
        # reactions" — command references become first-class): `trigger
        # Account::Debit`, a bare constant `ConstShim` resolves the same
        # way `reference_to Account` always has, not a quoted verb string.
        # Matches the qualified-or-not shape a saga's own `dispatch`
        # command name takes — see `Naming.command_ref`'s own header for
        # how the `::`/`.` rewrite works, and `SagaInterpreter#qualified`
        # for why an unqualified form is always enough (same-domain is
        # the fallback, so `Account::Debit` and `Banking::Account::Debit`
        # mean the same thing here).
        #
        # Legacy under shadow-parsing (S0a's own bridge) — frozen era
        # text still writes the quoted form.
        #
        # `["Policy", "trigger"] => :trigger_impl` is in
        # `GenericDispatch::BOOTSTRAP_CALLS_FALLBACK`, which carries every `calls:`-routed row
        # unconditionally — this one is also exercised during boot itself, since every
        # self-hosted policy declares a trigger.
        #
        # @param command_ref [Symbol, String, Module] the command, as a bare constant (a
        #   `ScopedConstant` module `ConstShim` resolves) or, under shadow-parsing, quoted text
        # @param with [Hash{Symbol => Object}, nil] a projection from the triggering event's payload
        #   onto the command's own arguments; a Symbol value names an event field, anything else is
        #   a literal; `nil` forwards the whole event payload verbatim
        # @return [void]
        # @raise [Bluebook::DSL::Malformed] if `command_ref` is quoted text outside shadow-parsing
        def trigger_impl(command_ref, with: nil)
          if command_ref.is_a?(::String) && !MetaValidator.shadow_parsing?
            raise Malformed,
                  "#{@name}'s trigger #{command_ref.inspect} is quoted text — give the bare command " \
                  "constant instead, e.g. trigger Account::Debit"
          end

          @trigger_command = Naming.command_ref(command_ref)
          @with_spec = (with || {}).to_a
          @projection_declared = !with.nil?
        end

        # Records the domain this policy's trigger reaches into.
        #
        # `across "Notifications"` names the domain a trigger reaches into.
        # `expect_undelivered: true` declares that this domain expects that
        # target never to be reached (no such domain, on purpose), which
        # `ModelCheck` holds it to in both directions. Reached through
        # `calls: "across_impl"` rather than the generic single-fill
        # coercion, because `expect_undelivered:` is a keyword argument the
        # generic coercion cannot take.
        #
        # @param domain [String, Symbol] the target domain's name
        # @param expect_undelivered [Boolean] whether this domain expects `across`'s target to
        #   name no real domain; `ModelCheck` holds it to that in both directions
        # @return [void]
        def across_impl(domain, expect_undelivered: false)
          @target_domain = domain.to_s
          @expect_undelivered = expect_undelivered == true
        end

        # Records the guard predicate that decides whether this policy applies to a triggering
        # event.
        #
        # **The guard** — same extraction CommandBuilder#given/#ensures already
        # use (Ports::Extraction reads the block's source ; the block itself
        # is never called, here or at runtime — Runtime::PolicyInterpreter
        # evaluates the extracted text through the same
        # Bluebook::Expression::Evaluator a command's own given/ensures run
        # through). No description argument the way given/ensures each
        # carry one : a given's description becomes a GivenNotMet message,
        # and a where that does not hold refuses nothing — it just means
        # this policy does not apply to this event, exactly like an
        # `event_qualifier` miss, which carries no message either.
        #
        # Evaluated against the triggering event's own payload, not a
        # stored record — a policy reacts to what just happened, and has no
        # aggregate instance of its own to read state from.
        #
        # @yield the guard predicate, extracted as source text and evaluated later by
        #   `Runtime::PolicyInterpreter` against the triggering event's payload; never called here
        # @return [void]
        # @raise [Bluebook::DSL::Malformed] if the block's source could not be extracted, or if it
        #   references a pattern `Expression::AstJson.refuse_unshared_patterns!` does not share
        def where(&predicate)
          canonical = Ports::Extraction.canonical(predicate)

          if canonical.to_s.empty?
            raise Malformed,
                  "#{@name}'s where did not survive extraction — its source " \
                  "could not be read, so no other runtime could ever evaluate it"
          end

          # C3.6 — the same PatternSubset check every rule site gets.
          Expression::AstJson.refuse_unshared_patterns!(Expression::AstJson.emit_predicate(canonical),
                                                        owner: @name, word: "where")
          @where = canonical
        end

        # **The fan-out source** — a query verb, "Aggregate.query_name" or
        # "Domain::Aggregate.query_name", the same qualified-or-not shape a
        # saga's own `dispatch` command name already takes
        # (SagaInterpreter#qualified). Runtime::PolicyInterpreter runs the
        # named query against the triggering event's own payload and fires
        # `trigger` once per row, instead of once for the event.
        # `for_each` — item #13's full metaprogrammed dispatch, slice 1:
        # same shape as `on`, above.

        # Builds the `Policy` this builder has accumulated.
        #
        # @return [Bluebook::Policy] the built policy, carrying every field set by `on`,
        #   `trigger`, `across`, `where`, `for_each`, and `with:`
        def build
          Policy.new(
            name:               @name,
            on_event:           @on_event,
            trigger_command:    @trigger_command,
            target_domain:      @target_domain,
            expect_undelivered: @expect_undelivered || false,
            where:              @where,
            for_each:           @for_each,
            with_spec:          @with_spec || []
          ).tap { |policy| policy.instance_variable_set(:@projection_declared, !!@projection_declared) }
        end

        # Builds a `Policy` from a `policy "Name" do ... end` block.
        #
        # @param name [String] the policy's own name
        # @yield the policy's body, `instance_eval`'d against a new builder
        # @return [Bluebook::Policy] the built policy
        def self.build(name, &block)
          builder = new(name)
          builder.instance_eval(&block) if block
          builder.build
        end
      end
    end
  end
end
