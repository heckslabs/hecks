require_relative "word_gate"
module Hecks
  module Bluebook
    module DSL
      # Parses one `operation`/`tells`/`asks` block inside a `domain_port`
      # into a `PortOperation` — its own attributes (the external fact's
      # payload) plus either the events it `emits` (inbound) or the
      # `answers`/`refuses` pair naming its two possible outcomes (outbound).
      # `to:` records which aggregate the operation routes to as dispatch
      # metadata, never as an attribute — see `to:`'s own comment below.
      class PortOperationBuilder
        GRAMMAR_CONTEXT = "PortOperation".freeze

        include AttributeCollector
        include WordGate

        # `to:` — the sanctioned replacement for `reference_to` inside an
        # operation body: `reference_to_impl`'s own refusal message tells
        # authors to "pass the receiving aggregate in to:", and this is
        # the argument DomainPort's own grammar (domain_port.bluebook)
        # gives operation/tells/asks to receive it.
        #
        # **Genuine routing metadata, not an attribute** — matching
        # rust/parser/src/parse/domain_port.rs's own header comment ("The
        # receiving aggregate is routing metadata supplied by to:, not an
        # operation attribute"), which anticipated this shape before either
        # side actually built it. Stored separately (below, threaded to
        # PortOperation as `to:`) rather than reusing reference_to_impl's
        # own attribute-adding path — Dispatcher#port_invocation
        # (lib/hecks/runtime/dispatcher.rb) is the one place that resolves
        # routing at dispatch time; it gained a second, purely additive
        # branch for this (falls back to a plain attribute named for the
        # owning aggregate's own identified_by field, the same "declare
        # only external facts with attribute" the refusal message
        # describes) rather than folding `to:` into identity_attribute's
        # existing Reference-attribute scan, which every operation already
        # in the corpus (Banking, pizzas, lifeadelics' own vendored
        # PaymentGateway) still relies on unchanged.
        #
        # @param name [String] the operation's name
        # @param to [Symbol, String, Module, nil] the aggregate the operation routes to; stored
        #   demodulised, and nil when the operation names none
        # @param owner [String, nil] name of the aggregate the enclosing port is declared on
        # @param direction [Symbol] `:inbound` for `operation`/`tells`, `:outbound` for `asks`
        def initialize(name, to: nil, owner: nil, direction: :inbound)
          @name      = name
          @to        = to && Naming.demodulise(to)
          @owner     = owner
          @direction = direction
          @emits     = []
        end

        # Refuses `reference_to` inside an operation body, except while shadow-parsing, where it
        # adds the reference attribute frozen era text declared.
        #
        # Always an attribute, never the self-reference `CommandBuilder`
        # spells — a port operation has no `creates?`/`acts_on` distinction
        # to protect, so there is nothing for the self-reference branch to be
        # for here. `reference_to Payment, as: :payment_id` reads the same
        # even though the target happens to equal the owning aggregate.
        # Answers the `reference_to` word through the table's `calls:`
        # column — item #13's full metaprogrammed dispatch (slice 4b).
        # Bootstrap-reachable, in `GenericDispatch::BOOTSTRAP_CALLS_FALLBACK`.
        #
        # Disabled, #335 — kept only for MetaValidator's own shadow-parsing
        # pass (the self-hosted grammar's own KeywordSeed/ArgumentSeed rows
        # for "reference_to" in this context are themselves declared using
        # this construct, one level up — deleting the Ruby method would
        # break the language describing itself, not just old domain
        # authors). Every real domain author reaches `to:` instead, above —
        # a genuinely different mechanism now, not a relocated spelling of
        # this one (see `to:`'s own comment).
        #
        # @param type [Symbol, String, Module] the referenced aggregate, written as a bare constant
        # @param as [Symbol, nil] the attribute's name; nil derives it from the target, as in
        #   `:payment_id` under shadow-parsing
        # @return [nil] nothing useful; the reference lands in `attributes`
        # @raise [Bluebook::DSL::Malformed] always outside shadow-parsing, since routing belongs
        #   in `to:`; under shadow-parsing, if the attribute name is already declared
        def reference_to_impl(type, as: nil)
          unless MetaValidator.shadow_parsing?
            raise Malformed,
                  "#{@name}.reference_to is behavioral routing, not retained domain state — " \
                  "pass the receiving aggregate in to: and declare only external facts with attribute"
          end

          add_reference!(type, as: as)
        end

        # Names one event an inbound operation records once the external fact has arrived.
        #
        # @param event_name [String, Symbol] the event's name, such as `"PaymentSettled"`
        # @return [Array<String>] every event named so far, this one last
        def emits(event_name) = @emits << event_name.to_s

        # The two halves of an `asks`. An outbound call has exactly two
        # endings and the chapter names both — `answers` for what came back,
        # `refuses` for what the outside said instead. They are separate words
        # rather than two `emits` because a reader has to be able to tell them
        # apart without reading the adapter: one is the thing you wanted, the
        # other is the thing you have to handle.
        # `answers`/`refuses` — item #13's full metaprogrammed dispatch,
        # slice 1 (whole-project table-unification survey): both a bare,
        # kind-driven coerce-and-assign with nothing else, now executed
        # by `GenericDispatch`.

        # Assembles the operation, refusing words that belong to the other direction.
        #
        # @return [Bluebook::PortOperation] the operation with its attributes, events and routing
        # @raise [Bluebook::DSL::Malformed] if an inbound operation declares no `emits` or
        #   declares `answers`/`refuses`, or an outbound one declares `emits` or lacks either
        #   `answers` or `refuses`
        def build
          outbound = @direction == :outbound
          refuse_wrong_words!(outbound)

          operation = PortOperation.new(
            name: @name, attributes: attributes, emits: @emits,
            direction: @direction, answers: @answers, refuses: @refuses, to: @to
          )

          # An inbound operation still has to say something. Only inbound: an
          # `asks` says it with `answers`/`refuses` instead, and
          # `refuse_wrong_words!` above has already insisted on both.
          if !outbound && @emits.empty?
            raise Malformed,
                  "#{@name} declares no emits — an operation with nothing to say " \
                  "afterward is a call into nothing"
          end

          operation
        end

        private

        # The one place a reference attribute actually gets added — both
        # `to:` (initialize, above) and reference_to_impl's own shadow-
        # parsing branch call this, so there is exactly one real
        # implementation of "carry a Reference-typed external fact,"
        # not two that could drift.
        def add_reference!(type, as: nil)
          target = Naming.demodulise(type)
          attribute_impl(as || default_reference_name(target), Reference.new(target))
        end

        # **Each direction refuses the other's words**. `emits` on an `asks` looks
        # right and is not: it would name one ending and leave the other
        # nowhere. `answers` on a `tells` is worse — there is no channel back
        # to an inbound caller at all, so it would read as a promise the
        # runtime cannot keep.
        def refuse_wrong_words!(outbound)
          if outbound
            unless @emits.empty?
              raise Malformed, "#{@name} is an asks and declares emits — name its two endings with " \
                               "answers and refuses instead"
            end
            unless @answers
              raise Malformed, "#{@name} declares no answers — an ask with no word for what came " \
                               "back cannot be reacted to"
            end
            unless @refuses
              raise Malformed, "#{@name} declares no refuses — an ask that cannot fail is a call " \
                               "into a system you do not control, pretending otherwise"
            end
          else
            if @answers || @refuses
              raise Malformed, "#{@name} is a tells and declares #{@answers ? 'answers' : 'refuses'} — " \
                               "an inbound fact has no channel back to whoever sent it"
            end
          end
        end

        # Evaluates one operation block against a fresh builder and returns what it built.
        #
        # `private` above (scoping the instance methods between it and here)
        # doesn't reach a singleton method — correctly so: `.build` is this
        # builder's real public entry point (DomainPortBuilder calls it),
        # never meant to be private.
        #
        # @param name [String] the operation's name
        # @param to [Symbol, String, Module, nil] the aggregate the operation routes to, or nil
        # @param owner [String, nil] name of the aggregate the enclosing port is declared on
        # @param direction [Symbol] `:inbound` for `operation`/`tells`, `:outbound` for `asks`
        # @yield the operation body, evaluated with the builder as `self`; may be omitted
        # @return [Bluebook::PortOperation] the built operation
        # @raise [Bluebook::DSL::Malformed] if the body uses the other direction's words, omits
        #   the ones its own direction requires, or uses a word the grammar does not admit
        # rubocop:disable-next Lint/IneffectiveAccessModifier
        def self.build(name, to: nil, owner: nil, direction: :inbound, &block)
          builder = new(name, to: to, owner: owner, direction: direction)
          builder.instance_eval(&block) if block
          builder.build
        end
      end
    end
  end
end
