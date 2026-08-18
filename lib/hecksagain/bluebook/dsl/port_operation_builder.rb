require_relative "word_gate"
module Hecksagain
  module Bluebook
    module DSL
      class PortOperationBuilder
        GRAMMAR_CONTEXT = "PortOperation"

        include AttributeCollector
        include WordGate

        def initialize(name, owner: nil, direction: :inbound)
          @name      = name
          @owner     = owner
          @direction = direction
          @emits     = []
        end

        # ALWAYS an attribute, never the self-reference `CommandBuilder`
        # spells — a port operation has no `creates?`/`acts_on` distinction
        # to protect, so there is nothing for the self-reference branch to be
        # FOR here. `reference_to Payment, as: :payment_id` reads the same
        # even though the target happens to equal the owning aggregate.
        def reference_to(type, as: nil)
          target = Naming.demodulise(type)
          attribute_impl(as || default_reference_name(target), Reference.new(target))
        end

        def emits(event_name) = @emits << event_name.to_s

        # THE TWO HALVES OF AN `asks`. An outbound call has exactly two
        # endings and the chapter names both — `answers` for what came back,
        # `refuses` for what the outside said instead. They are separate words
        # rather than two `emits` because a reader has to be able to tell them
        # apart without reading the adapter: one is the thing you wanted, the
        # other is the thing you have to handle.
        # `answers`/`refuses` — item #13's full metaprogrammed dispatch,
        # slice 1 (whole-project table-unification survey): both a bare,
        # kind-driven coerce-and-assign with nothing else, now executed
        # by `GenericDispatch`.

        def build
          outbound = @direction == :outbound
          refuse_wrong_words!(outbound)

          operation = PortOperation.new(
            name: @name, attributes: attributes, emits: @emits,
            direction: @direction, answers: @answers, refuses: @refuses
          )

          # AN INBOUND OPERATION STILL HAS TO SAY SOMETHING. Only inbound: an
          # `asks` says it with `answers`/`refuses` instead, and
          # `refuse_wrong_words!` above has already insisted on both.
          raise Malformed,
                "#{@name} declares no emits — an operation with nothing to say " \
                "afterward is a call into nothing" if !outbound && @emits.empty?

          # Only enforced when this operation belongs to ONE aggregate — a
          # port declared bare at a hecksagon's root has no single owner for
          # an emitted event to be ABOUT, so nothing here can require one.
          if @owner
            raise Malformed,
                  "#{@name} names no reference_to #{@owner} — an operation needs one to " \
                  "say which #{@owner} its emitted event belongs to" unless operation.identity_attribute(@owner)
          end

          operation
        end

        private

        # EACH DIRECTION REFUSES THE OTHER'S WORDS. `emits` on an `asks` looks
        # right and is not: it would name one ending and leave the other
        # nowhere. `answers` on a `tells` is worse — there is no channel back
        # to an inbound caller at all, so it would read as a promise the
        # runtime cannot keep.
        def refuse_wrong_words!(outbound)
          if outbound
            raise Malformed, "#{@name} is an asks and declares emits — name its two endings with " \
                             "answers and refuses instead" unless @emits.empty?
            raise Malformed, "#{@name} declares no answers — an ask with no word for what came " \
                             "back cannot be reacted to" unless @answers
            raise Malformed, "#{@name} declares no refuses — an ask that cannot fail is a call " \
                             "into a system you do not control, pretending otherwise" unless @refuses
          else
            raise Malformed, "#{@name} is a tells and declares #{@answers ? 'answers' : 'refuses'} — " \
                             "an inbound fact has no channel back to whoever sent it" if @answers || @refuses
          end
        end

        def self.build(name, owner: nil, direction: :inbound, &block)
          builder = new(name, owner: owner, direction: direction)
          builder.instance_eval(&block) if block
          builder.build
        end
      end
    end
  end
end
