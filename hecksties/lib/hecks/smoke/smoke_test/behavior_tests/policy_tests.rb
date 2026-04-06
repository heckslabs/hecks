# HecksTemplating::SmokeTest::PolicyTests
#
# Tests reactive policies by verifying that triggering commands
# produce the expected events in the event log. Skips cross-domain
# policies where the trigger event comes from another bounded context.
#
#   test_policies(results)
#
module HecksTemplating
  class SmokeTest
    module PolicyTests
      private

      def test_policies(results)
        @domain.aggregates.each do |agg|
          agg.policies.each do |pol|
            next unless pol.reactive?

            # Skip cross-domain policies — the trigger event comes from
            # another bounded context that isn't running in this server.
            trigger_cmd = find_command_by_event(pol.event_name)
            next unless trigger_cmd

            triggered_event = find_event_name(pol.trigger_command)
            next unless triggered_event

            results << check_events_contain(
              [pol.event_name, triggered_event],
              "Policy #{pol.name}"
            )
          end
        end

        # Also check domain-level policies
        @domain.policies.each do |pol|
          next unless pol.reactive?
          trigger_cmd = find_command_by_event(pol.event_name)
          next unless trigger_cmd

          triggered_event = find_event_name(pol.trigger_command)
          next unless triggered_event

          results << check_events_contain(
            [pol.event_name, triggered_event],
            "Domain policy #{pol.name}"
          )
        end
      end
    end
  end
end
