
module Hecksagain
  module Runtime
    class PolicyInterpreter
      attr_reader :registry

      def initialize(registry, door:)
        @registry = registry
        @door     = door
      end

      def react(event, domain)
        policies_for(event, domain).each do |policy|
          @registry.reaction_log << deliver(policy, event, domain)
        end
      end

      private

      def policies_for(event, domain)
        bluebook = @registry.bluebook(domain)
        return [] unless bluebook

        emitting = Naming.demodulise(event.aggregate)

        bluebook.policies.select do |policy|
          policy.event_name == event.name &&
            (policy.event_qualifier.nil? || policy.event_qualifier == emitting)
        end
      end

      def deliver(policy, event, domain)
        target = "#{policy.target_domain || domain}::#{policy.trigger_command}"
        record = { policy: policy.name, on: event.name, trigger: target }

        if @door.reaction_depth_reached?
          return record.merge(delivered: false,
                              reason: "reaction depth #{@door.max_reaction_depth} reached")
        end

        @door.reenter(target, **event.payload.transform_keys(&:to_sym))
        record.merge(delivered: true)
      rescue *DOMAIN_REFUSALS => error
        # The target refused — a fact about the domain, recorded and not
        # fatal to the command that emitted the event. Anything else (a
        # NoMethodError in an interpreter, an unknown verb in the policy's
        # own declaration) is a DEFECT and flies : it used to land here too,
        # as `delivered: false` beside every legitimate refusal, which made
        # a crashed runtime read as normal operation.
        record.merge(delivered: false, reason: error.message)
      end
    end
  end
end
