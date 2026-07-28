# CommandRules — what a command obeys, WHATEVER it acts on.
#
# An aggregate record and one element inside it are different subjects, but a
# command means the same thing against either : the givens must hold, the
# state machine must admit the move, a Symbol reads an argument, arithmetic is
# Integer-or-nothing, and what was announced is announced once the state is
# stored.
#
# These rules were reached, at first, by publishing four of CommandInterpreter's
# internal steps so the element path could call them. That made
# EntityInterpreter a partial reuser of another interpreter's guts rather than
# a peer, and the arithmetic rule was NOT reached at all — the element path
# carried its own byte-identical copy of the Integer-or-nothing check, error
# strings and all, with a comment admitting as much.
#
# Two copies of a money-safety invariant is how a ledger drifts. Worse, parity
# compares refusal WORDING : tighten one message and not the other, and whether
# the split ever surfaces depends entirely on whether the corpus happens to
# drive both paths. So the rule lives here, once, and both paths call it.
#
#   rules = CommandRules.new(registry)
#   rules.enforce_givens(subject, command, args)

module Hecksagain
  module Runtime
    class CommandRules
      attr_reader :registry

      def initialize(registry)
        @registry = registry
      end

      # All givens must hold. A refused command leaves the subject untouched
      # because nothing has been written yet.
      def enforce_givens(subject, command, args)
        command.givens.each do |given|
          next if Bluebook::Expression::Evaluator.call(given.canonical, subject, args)

          raise GivenNotMet, "#{command.name} refused — #{given.description}"
        end
      end

      # The lifecycle's admission rule. Nil when the command is not part of
      # the machine ; the admitted StateTransition when it is and the current
      # state allows it ; LifecycleRefused when the machine says no. A
      # transition with no `from:` admits any state. The helpers this walks
      # (transitions_for, constrained?) sat on IR::Lifecycle from the day it
      # was written, called by nothing — the same shelf IR::Policy's matchers
      # waited on.
      #
      # `declaring` is the aggregate for a record and the ENTITY for an
      # element : an entry has its own machine, and that is the whole reason
      # an entity is an entity.
      def admissible_transition(declaring, command, subject)
        lifecycle = declaring.lifecycle
        return nil unless lifecycle

        candidates = lifecycle.transitions_for(command.name)
        return nil if candidates.empty?

        current  = subject[lifecycle.field].to_s
        admitted = candidates.find { |t| !t.constrained? || Array(t.from).include?(current) }
        return admitted if admitted

        allowed = candidates.flat_map { |t| Array(t.from) }.uniq
        raise LifecycleRefused,
              "#{command.name} refused — #{lifecycle.field} is #{current.inspect}, and " \
              "#{command.name} moves it only from #{allowed.map(&:inspect).join(' or ')}"
      end

      # A Symbol naming a command attribute reads that argument ; anything else
      # is a literal.
      def resolve_source(source, args)
        return args[source] if source.is_a?(Symbol) && args.key?(source)

        source
      end

      # Integer cents or nothing. Money is the reason these ops exist, and
      # IEEE 754 has no place in a ledger — so a non-Integer amount is refused
      # LOUDLY rather than coerced. (Hecks's runtime falls back to ±1 when the
      # amount will not read as a number ; a balance moving by one cent because
      # the caller sent "lots" is exactly the silent wrongness this refuses.)
      #
      # An element's count drifting on a coerced word is the same disease one
      # level down, which is why there is one rule and not two.
      def arithmetic(current, amount, target, sign)
        op      = sign.positive? ? "increment" : "decrement"
        current ||= 0

        unless amount.is_a?(Integer)
          raise TypeMismatch, "#{op} of #{target} needs an Integer, got #{amount.inspect}"
        end
        unless current.is_a?(Integer)
          raise TypeMismatch, "#{op} of #{target} needs an Integer #{target}, got #{current.inspect}"
        end

        current + (sign * amount)
      end

      # The sign a mutation's op carries. Written once so the two call sites
      # cannot disagree about which way `decrement` goes.
      def sign_of(op) = op == :increment ? 1 : -1

      # An event is a promise that the state behind it survived, so this is
      # called only after the subject's record is stored. The event rides the
      # AGGREGATE's name either way : outside the boundary, the parent is the
      # only addressable thing.
      def emit(command, domain, aggregate, instance, args, repository)
        command.emits.map do |event_name|
          event = Event.new(
            name:        event_name,
            aggregate:   "#{domain}::#{aggregate.name}",
            id:          instance.id,
            payload:     args,
            occurred_at: Time.now.utc.iso8601
          )
          @registry.event_log << event
          repository.record_event(event) if repository.respond_to?(:record_event)
          event
        end
      end
    end
  end
end
