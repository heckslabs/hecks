
module Hecksagain
  module Runtime
    class CommandRules
      attr_reader :registry

      def initialize(registry)
        @registry = registry
      end

      def enforce_givens(subject, command, args)
        command.givens.each do |given|
          next if Bluebook::Expression::Evaluator.call(given.canonical, subject, args)

          raise GivenNotMet, "#{command.name} refused — #{given.description}"
        end
      end

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

      def resolve_source(source, args)
        return args[source] if source.is_a?(Symbol) && args.key?(source)

        source
      end

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

      def sign_of(op) = op == :increment ? 1 : -1

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
