module Hecks
  module Fuzzing
    module Properties
      # Property: every reaction a replay logged is the one its policy declares.
      #
      # `PolicyInterpreter` selects policies by `event_name` and builds the trigger from
      # `target_domain` and `trigger_command`; this reads each logged reaction back against the
      # declaration, so a policy that fired on an event it never named, or dispatched somewhere
      # it never declared, is caught.
      module PolicyWiring
        # Every `history[:reactions]` entry names a declared policy, was logged for the event
        # that policy answers (and one that happened), and triggered the declared target.
        #
        # @param history [Hash] a replayed history, as returned by `Fuzzing::Replay.call`
        # @return [true, String] true, or a message naming each reaction that disagrees
        def policy_reactions_follow_declared_wiring(history)
          bluebooks = history.fetch(:bluebooks, {})
          events = Array(history[:events])

          offenders = Array(history[:reactions]).filter_map { |reaction| wiring_offender(reaction, bluebooks, events) }
          offenders.empty? || offenders.uniq.join("; ")
        end

        # One message for a reaction no declaration of its policy accounts for; nil when one does.
        #
        # A policy name can repeat across domains, so a reaction passes when any declaration
        # of that name agrees with it on all three of event, trigger and qualifier.
        def wiring_offender(reaction, bluebooks, events)
          declared = declared_policies(reaction[:policy], bluebooks)
          return "reaction names policy #{reaction[:policy]}, which no loaded bluebook declares" if declared.empty?

          answering = declared.select { |policy, _home| policy.event_name == reaction[:on].to_s }
          return unanswered_message(reaction, declared) if answering.empty?

          targeted = answering.select { |policy, home| declared_trigger(policy, home) == reaction[:trigger].to_s }
          return misrouted_message(reaction, answering) if targeted.empty?

          return if targeted.any? { |policy, _home| event_happened?(events, policy, reaction[:on]) }

          "policy #{reaction[:policy]} reacted to #{reaction[:on]}, but no such event was emitted in this history"
        end

        # Every `[policy, home_domain]` pair declared under `name`, across all loaded bluebooks.
        def declared_policies(name, bluebooks)
          bluebooks.flat_map do |home, bluebook|
            bluebook.policies.select { |policy| policy.name == name.to_s }.map { |policy| [policy, home.to_s] }
          end
        end

        # The trigger string the runtime builds: the target domain, else the policy's own home.
        def declared_trigger(policy, home)
          "#{policy.target_domain || home}::#{policy.trigger_command}"
        end

        # Whether `events` holds an emission of `name` the policy's event qualifier admits.
        def event_happened?(events, policy, name)
          events.any? do |event|
            event[:name] == name.to_s &&
              (policy.event_qualifier.nil? || event[:aggregate].to_s.split("::").last == policy.event_qualifier)
          end
        end

        def unanswered_message(reaction, declared)
          named = declared.map { |policy, _home| policy.event_name }.uniq.join(" / ")
          "policy #{reaction[:policy]} reacted to #{reaction[:on]}, but it declares #{named}"
        end

        def misrouted_message(reaction, answering)
          named = answering.map { |policy, home| declared_trigger(policy, home) }.uniq.join(" / ")
          "policy #{reaction[:policy]} triggered #{reaction[:trigger]} on #{reaction[:on]}, but it declares #{named}"
        end
      end
    end
  end
end
