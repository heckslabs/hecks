
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

          raise GivenNotMet, "#{command.hecks_name} refused — #{given.description}"
        end
      end

      def admissible_transition(declaring, command, subject)
        lifecycle = declaring.lifecycle
        return nil unless lifecycle

        candidates = lifecycle.transitions_for(command.hecks_name)
        return nil if candidates.empty?

        current  = subject[lifecycle.field].to_s
        admitted = candidates.find { |t| !t.constrained? || Array(t.from).include?(current) }
        return admitted if admitted

        allowed = candidates.flat_map { |t| Array(t.from) }.uniq
        raise LifecycleRefused,
              "#{command.hecks_name} refused — #{lifecycle.field} is #{current.inspect}, and " \
              "#{command.hecks_name} moves it only from #{allowed.map(&:inspect).join(' or ')}"
      end

      def resolve_source(source, args)
        return args[source] if source.is_a?(Symbol) && args.key?(source)

        source
      end

      def arithmetic(current, amount, target, sign)
        op      = sign.positive? ? "increment" : "decrement"
        current ||= 0

        if current.is_a?(Value) && amount.is_a?(Value)
          return arithmetic_value_object(current, amount, target, sign, op)
        end

        unless amount.is_a?(Integer)
          raise TypeMismatch, "#{op} of #{target} needs an Integer, got #{amount.inspect}"
        end
        unless current.is_a?(Integer)
          raise TypeMismatch, "#{op} of #{target} needs an Integer #{target}, got #{current.inspect}"
        end

        current + (sign * amount)
      end

      def arithmetic_value_object(current, amount, target, sign, op)
        current_fields = current.to_h
        amount_fields  = amount.to_h
        shared_numeric = current_fields.keys.select do |field|
          current_fields[field].is_a?(Integer) && amount_fields[field].is_a?(Integer)
        end
        unless shared_numeric.size == 1
          raise TypeMismatch,
                "#{op} of #{target} needs a value object with one shared Integer field"
        end

        field = shared_numeric.first
        current.with(field, current[field] + (sign * amount[field]))
      end

      def sign_of(op) = op == :increment ? 1 : -1

      def emit(command, domain, aggregate, instance, args, repository)
        command.emits.map do |event_name|
          event = Event.new(
            name:        event_name,
            aggregate:   "#{domain}::#{aggregate.hecks_name}",
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
