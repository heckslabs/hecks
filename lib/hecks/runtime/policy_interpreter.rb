require_relative "../naming"
require_relative "errors"
require_relative "query_interpreter"
require_relative "reaction_invocation"
require_relative "refusal_wording"
require_relative "value"
require_relative "policy_interpreter/fan_out"
require_relative "policy_interpreter/arguments"
require_relative "../bluebook/expression/evaluator"

module Hecks
  module Runtime
    # Fires the declared `policy` reactions triggered by one just-emitted event,
    # recording every outcome on the reaction log.
    class PolicyInterpreter
      include FanOut
      include Arguments

      attr_reader :registry

      # @param registry [Runtime::Registry] the booted registry whose loaded
      #   bluebooks are scanned for candidate policies
      # @param door [Runtime::Dispatcher] the dispatcher reactions re-enter through,
      #   and whose reaction-depth guard is checked before each delivery
      def initialize(registry, door:)
        @registry = registry
        @door     = door
      end

      # Fires every declared policy `event` triggers, recording each outcome on
      # the registry's reaction log. A policy whose `where` does not hold logs nothing.
      #
      # @param event [Runtime::Event] the just-emitted event to react to
      # @param domain [String, Symbol] the domain `event`'s own aggregate belongs
      #   to, the emitting domain's policies fire first
      # @param only [Array(Bluebook::Policy, String), nil] one `[policy, home_domain]`
      #   pair to run exactly (the outbox relay's consumer), instead of scanning every
      #   loaded bluebook for candidates
      # @param event_uid [String, nil] the outbox uid every consumer of this event shares, when the
      #   event was rebuilt from an outbox row; otherwise the event object itself is the identity
      # @return [void]
      def react(event, domain, only: nil, event_uid: nil)
        selected = only ? [only] : policies_for(event, domain)
        selected.each do |policy, home_domain|
          result = deliver(policy, event, home_domain)
          next if result.nil?

          # A for_each policy answers an array; Array(...) would explode a record Hash.
          identity = event_uid || event.object_id
          (result.is_a?(Array) ? result : [result]).each { |record| @registry.log_reaction(record, event: identity) }
        end
      end

      private

      # Scans every loaded bluebook, since a policy commonly lives in a different
      # domain than the event it reacts to. Returns [policy, home_domain] pairs: the
      # home domain is the fallback for a bare trigger or for_each route. Order is the
      # emitting domain first, then load order, matching Outbox::Fanout and the Rust kernel.
      def policies_for(event, domain)
        emitting = Naming.demodulise(event.aggregate)

        Outbox.bluebooks_home_first(@registry, domain).flat_map do |bluebook|
          matching = bluebook.policies.select do |policy|
            policy.event_name == event.name &&
              (policy.event_qualifier.nil? || policy.event_qualifier == emitting)
          end
          matching.map { |policy| [policy, bluebook.name] }
        end
      end

      # Evaluated against the event payload alone (a policy has no aggregate state).
      # Not rescued here: an EvaluationError must reach `deliver`'s defect rescue, not
      # read as a policy that declined to fire.
      def where_holds?(policy, event)
        return true if policy.where.to_s.empty?

        Bluebook::Expression::Evaluator.call_rule(policy.where_rule, {}, event.payload.transform_keys(&:to_sym))
      end

      def deliver(policy, event, domain)
        # `record` must exist before anything can raise: both rescues call `.merge` on it.
        target = "#{policy.target_domain || domain}::#{policy.trigger_command}"
        record = { policy: policy.name, on: event.name, trigger: target }

        return deliver_for_each(policy, event, domain, target, record) unless policy.for_each.to_s.empty?

        fire(policy, event, target, record)
      rescue *DOMAIN_REFUSALS => e
        record.merge(delivered: false, reason: e.message)
      rescue StandardError => e
        defect(policy, event, record, e, "firing #{target}")
      end

      # Fires the trigger once, unless the `where` declines it or the cascade is as deep as it
      # may go.
      def fire(policy, event, target, record)
        return nil unless where_holds?(policy, event)
        return depth_refusal(record) if @door.reaction_depth_reached?

        args = trigger_args(policy, event)
        @door.reenter(target, **reaction_invocation(target, args, policy, event))
        record.merge(delivered: true)
      end

      def depth_refusal(record)
        record.merge(delivered: false, reason: "reaction depth #{@door.max_reaction_depth} reached")
      end

      # A defect, not a refusal: recorded with `defect: true` and warned, never
      # re-raised. The emitting command has already persisted, so propagating would
      # only fail an unrelated caller. See DOMAIN_REFUSALS for why the two stay apart.
      def defect(policy, event, record, error, activity)
        warn "[hecks] defect in reaction — policy #{policy.name} on #{event.name} " \
             "#{activity}: #{error.class}: #{error.message}"
        record.merge(delivered: false, reason: error.message, defect: true, error_class: error.class.name)
      end
    end
  end
end
