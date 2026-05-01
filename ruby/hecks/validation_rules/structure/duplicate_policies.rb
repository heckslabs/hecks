# Hecks::ValidationRules::Structure::DuplicatePolicies
#
# @domain AcceptanceTest
#
# Refuses bluebooks that declare two or more reactive policies wired to
# the same `(event_name, trigger_command)` pair. Today those silently
# coexist — the runtime fires every matching policy in declaration
# order, so the trigger command runs once per duplicate. That's a
# cascade bug with no error message.
#
# Example of the bug:
#
#   policy "FatigueOnPulse" do
#     on "BodyPulse"
#     trigger "AccumulateFatigue"
#   end
#   policy "FatigueOnPulseDupe" do
#     on "BodyPulse"
#     trigger "AccumulateFatigue"
#   end
#
# Both fire on BodyPulse, both call AccumulateFatigue — the accumulate
# runs twice per pulse.
#
# Legitimate fan-out is preserved: different triggers on the same event
# (or the same trigger on different events) are not dupes. Different
# aggregates sharing a `(event, trigger)` pair via cross-domain wiring
# are keyed by `target_domain` so they don't collide with same-domain
# policies.
#
# Part of the ValidationRules::Structure group — run by +Hecks.validate+.
#
#   rule = DuplicatePolicies.new(domain)
#   rule.errors  # => ["2 policies share (event: BodyPulse, trigger: AccumulateFatigue) — ..."]
#
module Hecks
  module ValidationRules
    module Structure

    class DuplicatePolicies < BaseRule
      # Checks every reactive policy (aggregate-scoped and domain-level)
      # and returns one error per `(event, trigger)` pair shared by more
      # than one policy. The error names all colliding policies.
      #
      # @return [Array<ValidationMessage>] one message per duplicated pair
      def errors
        result = []

        group_by_key.each do |key, entries|
          next if entries.size < 2

          event, trigger, _target = key
          locations = entries.map { |_policy, context| context }
          names     = entries.map { |policy, _ctx| policy.name }.join(", ")

          result << error(
            "#{entries.size} policies share (event: #{event}, trigger: #{trigger}) — " \
            "the trigger fires once per matching policy, so #{trigger} will run " \
            "#{entries.size} times per #{event} event. Policies: #{names} " \
            "(#{locations.join('; ')}).",
            hint: "Delete the duplicates or collapse them into one policy. " \
                  "If fan-out is intentional, give each policy a distinct trigger command."
          )
        end

        result
      end

      private

      # Groups every reactive policy by `(event_name, trigger_command,
      # target_domain)`. Target domain disambiguates cross-domain
      # wiring — a domain policy shipping `Beat -> Tick` to
      # `OtherBluebook` is not a dupe of an in-domain `Beat -> Tick`.
      #
      # @return [Hash{Array => Array<[Policy, String]>}] key -> [[policy, context], …]
      def group_by_key
        groups = Hash.new { |h, k| h[k] = [] }

        @domain.aggregates.each do |agg|
          agg.policies.select(&:reactive?).each do |policy|
            key = [policy.event_name.to_s, policy.trigger_command.to_s, nil]
            groups[key] << [policy, "#{policy.name} in #{agg.name}"]
          end
        end

        @domain.policies.select(&:reactive?).each do |policy|
          key = [policy.event_name.to_s, policy.trigger_command.to_s, policy.target_domain]
          context = policy.target_domain ? "domain policy #{policy.name}@#{policy.target_domain}"
                                         : "domain policy #{policy.name}"
          groups[key] << [policy, context]
        end

        groups
      end
    end
    Hecks.register_validation_rule(DuplicatePolicies)
    end
  end
end
