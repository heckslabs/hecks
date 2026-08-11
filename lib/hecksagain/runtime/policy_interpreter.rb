require_relative "../naming"
require_relative "errors"


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
        # fatal to the command that emitted the event.
        record.merge(delivered: false, reason: error.message)
      rescue StandardError => error
        # A DEFECT, not a refusal — a NoMethodError in an interpreter, a
        # NameError from a missing constant, a TypeError from a bad
        # assumption : exactly the class of thing DOMAIN_REFUSALS
        # (errors.rb, see the comment above that constant) deliberately
        # excludes, and for the reason that comment gives at length —
        # folding a crash into the same `delivered: false` shape as an
        # ordinary refusal makes a broken runtime read as normal operation
        # in the log. This clause does not reopen that hole: it is a
        # SECOND, narrower rescue, tried only once the first one above has
        # already declined to match, so a legitimate refusal still takes
        # the branch above and a defect always takes this one.
        #
        # Catching it HERE is safe for a fact this method's caller cannot
        # see from where it sits: by the time `react` runs, the command
        # that EMITTED `event` has already succeeded and PERSISTED —
        # `Dispatcher#dispatch` calls `@policies.react` only after its own
        # `announced` events are already in hand. Letting this exception
        # keep propagating would not undo that command (nothing here is
        # transactional across aggregates) — it would only blow up the
        # ORIGINAL caller's `dispatch` call for a failure that happened in
        # a DIFFERENT command, one the caller never asked to run and has no
        # way to compensate for. So the defect is recorded, distinguishably
        # (`defect: true`, plus the error's own class — nothing here is
        # allowed to read like an ordinary refusal), warned to STDERR so it
        # is never silent, and left exactly where it happened for a human
        # to find — never re-raised, and never swallowed either.
        warn "[hecksagain] defect in reaction — policy #{policy.name} on #{event.name} " \
             "firing #{target}: #{error.class}: #{error.message}"
        record.merge(delivered: false, reason: error.message, defect: true, error_class: error.class.name)
      end
    end
  end
end
