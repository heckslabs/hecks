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

        # @param name [String] the policy's name, as written after `policy`
        def initialize(name)
          @name = name
        end

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
        # Overrides the generic single-fill coercion — item #13's
        # full metaprogrammed dispatch, slice 1 (whole-project
        # table-unification survey) — the same way
        # `trigger_impl` overrides its own generic default.
        #
        # @param event_ref [String, Symbol, Module] the event, quoted text or a bare constant
        #   such as `Account::AccountFrozen`
        # @return [String] the normalized reference, `"Domain.Event"` or `"Event"`
        def on_impl(event_ref)
          @on_event = Naming.event_ref(event_ref)
        end

        # `with:` — what the trigger is given, when the event's own shape
        # is not it. Omitted, the whole event payload forwards verbatim,
        # which is what every policy did before this existed.
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
        # Shares the qualified/unqualified reading this word and a
        # saga's own `dispatch` both give a command reference — see
        # `Naming.command_ref`'s own header for how the `::`/`.` rewrite
        # works, and `SagaInterpreter#qualified` for why an unqualified
        # form has always been enough (same-domain is the fallback, so
        # `Account::Debit` and `Banking::Account::Debit` mean the same
        # thing here).
        #
        # Legacy under shadow-parsing (S0a's own bridge) — frozen era
        # text still writes the quoted form.
        #
        # Answers the `trigger` word through the table's `calls:` column —
        # item #13's full metaprogrammed
        # dispatch (slice 4), same reasoning as `has_many_impl` above: not
        # bootstrap-reachable, reached through `calls:` with no fallback
        # needed.
        #
        # @param command_ref [Module, Symbol, String] the command to trigger, a bare constant
        #   such as `Account::Debit`, or (only under shadow-parsing) quoted text
        # @param with [Hash{Symbol => Symbol, Object}, nil] projects the event payload onto the
        #   command's own arguments; a Symbol value names a field on the triggering event,
        #   anything else is a literal; nil forwards the whole event payload verbatim
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

        # Names the domain the triggered command reaches across into.
        #
        # `across "Notifications"` names the domain a trigger reaches into.
        # `expect_undelivered: true` declares that this domain expects that
        # target never to be reached (no such domain, on purpose), which
        # `ModelCheck` holds it to in both directions. Reached through
        # `calls:` since it gained the named flag — the generic single-fill
        # coercion takes no keyword arguments.
        #
        # @param domain [String, Symbol] the target domain's name
        # @param expect_undelivered [Boolean] true when this domain expects the target never to
        #   exist, checked by `ModelCheck`
        # @return [void]
        def across_impl(domain, expect_undelivered: false)
          @target_domain = domain.to_s
          @expect_undelivered = expect_undelivered == true
        end

        # Declares a guard the triggering event's payload must satisfy for this policy to fire.
        #
        # The guard — same extraction CommandBuilder#given/#ensures already
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
        # @yield the guard body; evaluated for its extracted source, never called directly
        # @return [String] the guard's extracted source
        # @raise [Bluebook::DSL::Malformed] if the block's source could not be extracted, or
        #   uses a pattern construct engines disagree on
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

        # Assembles the declared event, guard, fan-out and trigger into a `Policy`.
        #
        # @return [Bluebook::Policy] the built policy
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

        # Evaluates a `policy` block against a fresh builder and returns what it built.
        #
        # @param name [String] the policy's name
        # @yield the policy body, evaluated with the builder as `self`; may be omitted
        # @return [Bluebook::Policy] the built policy
        # @raise [Bluebook::DSL::Malformed] if `trigger` is quoted text outside shadow-parsing,
        #   or `where`'s block source could not be extracted
        def self.build(name, &block)
          builder = new(name)
          builder.instance_eval(&block) if block
          builder.build
        end
      end
    end
  end
end
