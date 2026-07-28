# PolicyInterpreter — step 7. What the domain does about an event, once the
# state behind it is safely stored.
#
# A policy is a standing instruction that something else should follow, so the
# reflex fires after the event it waits for — after emit, for the same reason
# emit is last : a reaction is a promise the state behind it survived.
#
# It re-enters through the PUBLIC door rather than reaching into the command
# interpreter, because a reaction is not a special kind of dispatch — it is an
# ordinary one with nobody watching. That is why it holds a `door` and not a
# registry alone.
#
#   PolicyInterpreter.new(registry, door: dispatcher).react(event, "Pizzas")

module Hecksagain
  module Runtime
    class PolicyInterpreter
      attr_reader :registry

      def initialize(registry, door:)
        @registry = registry
        @door     = door
      end

      # The domain's reflex, finally connected. Four policies across the
      # corpus parsed, reached the IR, were agreed on byte-for-byte by both
      # parsers — and then fired nowhere, in either runtime. Parity was green
      # BECAUSE both discarded them equally : stage one cannot tell "both
      # understood it" from "both threw it away".
      #
      # EVERY reaction is recorded, delivered or not. A policy pointing at a
      # domain nobody loaded (pizzas' Notifications.Send) is a real thing to
      # know about, and swallowing it would rebuild the silence this fixes.
      def react(event, domain)
        policies_for(event, domain).each do |policy|
          @registry.reaction_log << deliver(policy, event, domain)
        end
      end

      private

      # A policy matches on the event NAME, and when its subscription is
      # qualified (`on "Order.Placed"`) on the emitting aggregate too. Both
      # helpers already existed on IR::Policy, unused — written for a
      # reaction that was never wired.
      def policies_for(event, domain)
        bluebook = @registry.bluebook(domain)
        return [] unless bluebook

        emitting = Naming.demodulise(event.aggregate)

        # DOMAIN-LEVEL ONLY. An aggregate-nested policy BUBBLES to the domain
        # at build time — the aggregate keeps a copy for its own IR, and
        # bluebook_builder says where the two agree : "the interpreter holds
        # them domain-level only". Reading both lists fired every nested
        # policy twice, which is what four reactions for two events looked
        # like before this comment was read.
        bluebook.policies.select do |policy|
          policy.event_name == event.name &&
            (policy.event_qualifier.nil? || policy.event_qualifier == emitting)
        end
      end

      # THE REACTION HAS NO ARGUMENT MAPPING, and that is deliberate. Hecks's
      # policy builder carries `with` / `map` / `defaults` / `translate` ;
      # this one narrowed to on/trigger/across because, as its own comment
      # says, "a keyword that parses and then does nothing is worse than one
      # that is absent". So the event's payload is the only honest input, and
      # a reaction needing more than it carries CANNOT complete.
      #
      # That is recorded rather than raised. The triggering command already
      # succeeded and its state is saved ; a consequence that cannot be
      # delivered does not retract it. What it must not do is vanish.
      def deliver(policy, event, domain)
        target = "#{policy.target_domain || domain}::#{policy.trigger_command}"
        record = { policy: policy.name, on: event.name, trigger: target }

        if @door.reaction_depth_reached?
          return record.merge(delivered: false,
                              reason: "reaction depth #{@door.max_reaction_depth} reached")
        end

        @door.reenter(target, **event.payload.transform_keys(&:to_sym))
        record.merge(delivered: true)
      rescue StandardError => error
        record.merge(delivered: false, reason: error.message)
      end
    end
  end
end
