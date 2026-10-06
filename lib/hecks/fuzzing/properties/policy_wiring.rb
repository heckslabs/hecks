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

        # A policy declared `expect_undelivered` is held to its word at runtime: its reaction is
        # never delivered, and an event it answers is never silently dropped.
        #
        # model_check holds the static half (a reachable target makes the declaration stale);
        # this is the dynamic half, over a replay. A policy with a `where` or a `for_each` may
        # legitimately log nothing, so the missing-reaction check skips those.
        #
        # @param history [Hash] a replayed history, as returned by `Fuzzing::Replay.call`
        # @return [true, String] true, or a message naming each policy that broke its declaration
        def declared_undelivered_policies_stay_undelivered(history)
          bluebooks = history.fetch(:bluebooks, {})
          reactions = Array(history[:reactions])
          events = Array(history[:events])

          offenders = declared_undelivered(bluebooks).flat_map do |policy, home|
            delivered_offenders(policy, reactions) + silent_offenders(policy, home, reactions, events)
          end
          offenders.empty? || offenders.uniq.join("; ")
        end

        # Every `[policy, home]` pair across the bluebooks that declares `expect_undelivered`.
        def declared_undelivered(bluebooks)
          bluebooks.flat_map do |home, bluebook|
            bluebook.policies.select(&:expect_undelivered).map { |policy| [policy, home.to_s] }
          end
        end

        def delivered_offenders(policy, reactions)
          delivered = reactions.select { |reaction| reaction[:policy] == policy.name && reaction[:delivered] == true }
          delivered.map do |reaction|
            "policy #{policy.name} declares expect_undelivered, but its reaction to #{reaction[:on]} was delivered"
          end
        end

        # An event the policy answers, with no reaction logged at all: a silent drop.
        def silent_offenders(policy, home, reactions, events)
          return [] if policy.guarded? || policy.fans_out?

          events.select { |event| answers_event?(policy, event) && !reacted_to?(reactions, policy, event) }
                .map { |event| silent_message(policy, home, event) }
        end

        def silent_message(policy, home, event)
          "policy #{policy.name} (#{home}) answers #{event[:name]}, which was emitted, yet logged no reaction"
        end

        def reacted_to?(reactions, policy, event)
          reactions.any? { |reaction| reaction[:policy] == policy.name && reaction[:on] == event[:name] }
        end

        def answers_event?(policy, event)
          event[:name] == policy.event_name &&
            (policy.event_qualifier.nil? || event[:aggregate].to_s.split("::").last == policy.event_qualifier)
        end

        # One message for a reaction no declaration of its policy accounts for; nil when one does.
        #
        # A policy name can repeat across domains, so a reaction passes when any declaration
        # of that name agrees with it on all three of event, trigger and qualifier.
        def wiring_offender(reaction, bluebooks, events)
          declared = declared_policies(reaction[:policy], bluebooks)
          return "reaction names policy #{reaction[:policy]}, which no loaded bluebook declares" if declared.empty?

          wiring_failure(reaction, declared, events)
        end

        # The first stage of event, trigger and happened-event that no declaration satisfies.
        def wiring_failure(reaction, declared, events)
          answering = declared.select { |policy, _home| policy.event_name == reaction[:on].to_s }
          return unanswered_message(reaction, declared) if answering.empty?

          targeted = answering.select { |policy, home| declared_trigger(policy, home) == reaction[:trigger].to_s }
          return misrouted_message(reaction, answering) if targeted.empty?

          phantom_failure(reaction, targeted, events)
        end

        def phantom_failure(reaction, targeted, events)
          return if targeted.any? { |policy, _home| event_happened?(events, policy, reaction[:on]) }

          phantom_message(reaction)
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
          events.any? { |event| event[:name] == name.to_s && answers_event?(policy, event) }
        end

        def unanswered_message(reaction, declared)
          named = declared.map { |policy, _home| policy.event_name }.uniq.join(" / ")
          "policy #{reaction[:policy]} reacted to #{reaction[:on]}, but it declares #{named}"
        end

        def misrouted_message(reaction, answering)
          named = answering.map { |policy, home| declared_trigger(policy, home) }.uniq.join(" / ")
          "policy #{reaction[:policy]} triggered #{reaction[:trigger]} on #{reaction[:on]}, but it declares #{named}"
        end

        def phantom_message(reaction)
          "policy #{reaction[:policy]} reacted to #{reaction[:on]}, but no such event was emitted in this history"
        end
      end
    end
  end
end
