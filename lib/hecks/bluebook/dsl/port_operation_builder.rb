require_relative "word_gate"
module Hecks
  module Bluebook
    module DSL
      # Parses one `operation`/`tells`/`asks` block into a `PortOperation`: its attributes plus
      # either the events it `emits` (inbound) or its `answers`/`refuses` pair (outbound).
      class PortOperationBuilder
        GRAMMAR_CONTEXT = "PortOperation".freeze

        include AttributeCollector
        include WordGate

        # `to:` is the sanctioned replacement for `reference_to` inside an operation body —
        # genuine routing metadata, not an attribute, resolved at dispatch time by
        # `Dispatcher#port_invocation` rather than folded into the ordinary attribute scan.
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

        # Refuses `reference_to` inside an operation body; a port operation has no self-reference
        # to protect the way `CommandBuilder`'s does. Kept only for MetaValidator's own
        # shadow-parsing pass, which still declares itself using this construct — every real
        # domain author reaches `to:` instead (see its own comment above).
        #
        # @raise [Bluebook::DSL::Malformed] always outside shadow-parsing; under shadow-parsing,
        #   if the attribute name is already declared
        def reference_to_impl(type, as: nil)
          unless MetaValidator.shadow_parsing?
            raise Malformed,
                  "#{@name}.reference_to is behavioral routing, not retained domain state — " \
                  "pass the receiving aggregate in to: and declare only external facts with attribute"
          end

          add_reference!(type, as: as)
        end

        # Names one event an inbound operation records once the external fact has arrived.
        def emits(event_name) = @emits << event_name.to_s

        # `answers`/`refuses`, the two halves of an `asks` — separate words rather than two
        # `emits` so a reader can tell what came back from what the outside refused, without
        # reading the adapter.

        # Assembles the operation, refusing words that belong to the other direction.
        #
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

          # Only inbound: an `asks` says it with `answers`/`refuses` instead, already enforced
          # above.
          if !outbound && @emits.empty?
            raise Malformed,
                  "#{@name} declares no emits — an operation with nothing to say " \
                  "afterward is a call into nothing"
          end

          operation
        end

        private

        # The one real implementation of "carry a Reference-typed external fact" — both `to:` and
        # `reference_to_impl`'s shadow-parsing branch call this, so there is nothing to drift.
        def add_reference!(type, as: nil)
          target = Naming.demodulise(type)
          attribute_impl(as || default_reference_name(target), Reference.new(target))
        end

        # Each direction refuses the other's words: `emits` on an `asks` names one ending and
        # leaves the other nowhere; `answers` on a `tells` promises a channel that never exists.
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
              raise Malformed, "#{@name} is a tells and declares #{@answers ? "answers" : "refuses"} — " \
                               "an inbound fact has no channel back to whoever sent it"
            end
          end
        end

        # Evaluates one operation block against a fresh builder and returns what it built;
        # `private` above doesn't reach this singleton method, since `.build` is the real entry.
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
