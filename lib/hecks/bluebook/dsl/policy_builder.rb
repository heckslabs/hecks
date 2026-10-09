require_relative "word_gate"
module Hecks
  module Bluebook
    module DSL
      # Parses a `policy "Name" do ... end` block into a `Policy`: the event it reacts to (`on`),
      # an optional `where` guard, an optional `for_each` fan-out, and the `trigger` it dispatches.
      class PolicyBuilder
        GRAMMAR_CONTEXT = "Policy".freeze

        include WordGate

        # @param name [String] the policy's own name, as given to `policy "Name" do ... end`
        def initialize(name)
          @name = name
        end

        # Records the event this policy reacts to.
        #
        # Reached through `calls: "on_impl"` because `on` admits both a bare constant
        # (`on Account::AccountFrozen`) and quoted text, not one single argument kind.
        #
        # @param event_ref [Symbol, String, Module] the event, as a bare constant (a
        #   `ScopedConstant` module `ConstShim` resolves) or quoted text
        # @return [void]
        def on_impl(event_ref)
          @on_event = Naming.event_ref(event_ref)
        end

        # Records the command this policy dispatches and how the event payload projects onto it.
        #
        # With `with:`, a Symbol value names a field on the triggering event and anything else is
        # a literal. Omitted, the whole payload forwards.
        # In `GenericDispatch::BOOTSTRAP_CALLS_FALLBACK`.
        #
        # @param command_ref [Symbol, String, Module] the command, as a bare constant or, under
        #   shadow-parsing, quoted text
        # @param with [Hash{Symbol => Object}, nil] event payload to command arguments;
        #   `nil` forwards the whole payload
        # @return [void]
        # @raise [Bluebook::DSL::Malformed] if `command_ref` is quoted text outside shadow-parsing
        def trigger_impl(command_ref, with: nil)
          raise Malformed, "#{@name} declares both a trigger and an ask — a policy does one" if @ask

          if command_ref.is_a?(::String) && !MetaValidator.shadow_parsing?
            raise Malformed,
                  "#{@name}'s trigger #{command_ref.inspect} is quoted text — give the bare command " \
                  "constant instead, e.g. trigger Account::Debit"
          end

          @trigger_command = Naming.command_ref(command_ref)
          @with_spec = (with || {}).to_a
          @projection_declared = !with.nil?
        end

        # Records the need this policy puts to the outside, in the domain's own words.
        #
        # The runtime resolves the name against the hecksagon's declared asks (the event's
        # aggregate and the ask's name) and dispatches the port operation the match names, as
        # `trigger` would have. `with:` projects the event onto the operation as it does for
        # `trigger`.
        #
        # @param name [Symbol, String] the need, such as `:check`
        # @param with [Hash{Symbol => Object}, nil] event payload to operation arguments;
        #   `nil` forwards the whole payload
        # @return [void]
        # @raise [Bluebook::DSL::Malformed] if the policy already triggers a command
        def ask_impl(name, with: nil)
          raise Malformed, "#{@name} declares both a trigger and an ask — a policy does one" if @trigger_command

          @ask = name.to_s
          @with_spec = (with || {}).to_a
          @projection_declared = !with.nil?
        end

        # Records the domain this policy's trigger reaches into.
        #
        # `expect_undelivered: true` declares that the target is expected never to be reached
        # (no such domain, on purpose); `ModelCheck` holds it to that in both directions.
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
        # The block's source is extracted and never called; a `where` that does not hold refuses
        # nothing, so unlike `given` it takes no description. It sees the event's payload only.
        #
        # @yield the guard predicate, extracted as source text and evaluated later by
        #   `Runtime::PolicyInterpreter` against the triggering event's payload; never called here
        # @return [void]
        # @raise [Bluebook::DSL::Malformed] if the block's source could not be extracted, or if it
        #   references a pattern `Expression::AstJson.refuse_unshared_patterns!` does not share, or
        #   calls a method the expression language does not have
        def where(&predicate)
          canonical = Ports::Extraction.canonical(predicate)

          if canonical.to_s.empty?
            raise Malformed,
                  "#{@name}'s where did not survive extraction — its source " \
                  "could not be read, so no other runtime could ever evaluate it"
          end

          ast = Expression::AstJson.emit_predicate(canonical)
          Expression::AstJson.refuse_unshared_patterns!(ast, owner: @name, word: "where")
          Expression::AstJson.refuse_unresolvable_lookups!(ast, owner: @name, word: "where")
          @where = canonical
        end

        # Builds the `Policy` this builder has accumulated.
        #
        # @return [Bluebook::Policy] the built policy, carrying every field set by `on`,
        #   `trigger`, `across`, `where`, `for_each`, and `with:`
        def build
          refuse_ask_across!
          Policy.new(**reaction_fields, **guard_fields)
                .tap { |policy| policy.instance_variable_set(:@projection_declared, !!@projection_declared) }
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

        private

        # What the policy reacts to and what it reaches.
        def reaction_fields
          { name: @name, on_event: @on_event, trigger_command: @trigger_command, ask: @ask,
            target_domain: @target_domain }
        end

        # What decides whether it fires, and what it hands over.
        def guard_fields
          { expect_undelivered: @expect_undelivered || false, where: @where, for_each: @for_each,
            with_spec: @with_spec || [] }
        end

        # An ask resolves against the ports of the domain it is declared in, so `across` has
        # nothing to add to it.
        def refuse_ask_across!
          return unless @ask && @target_domain

          raise Malformed, "#{@name} declares both an ask and across — an ask resolves in its own domain"
        end
      end
    end
  end
end
