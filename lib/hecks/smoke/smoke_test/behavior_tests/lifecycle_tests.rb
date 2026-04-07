# HecksTemplating::SmokeTest::LifecycleTests
#
# Tests aggregate lifecycle transitions over HTTP. Creates a fresh
# aggregate via browser form, verifies the default state, walks each
# transition in order (respecting from: constraints), and validates
# that all lifecycle events appear in the event log.
#
#   test_lifecycles(results)
#
module HecksTemplating
  class SmokeTest
    # HecksTemplating::SmokeTest::LifecycleTests
    #
    # Smoke tests for aggregate lifecycle transitions: creates, walks each transition, and validates events.
    #
    module LifecycleTests
      private

      def test_lifecycles(results)
        @domain.aggregates.each do |agg|
          lc = agg.lifecycle
          next unless lc

          plural = underscore(agg.name) + "s"
          agg_snake = underscore(agg.name)
          create_cmds, _ = partition_commands(agg, agg_snake)
          next if create_cmds.empty?

          # Create a fresh aggregate via browser form
          create_cmd = create_cmds.first
          cmd_snake = underscore(create_cmd.name)
          form_path = "/#{plural}/#{cmd_snake}/new"
          results.concat(submit_form(form_path, create_cmd, "lifecycle create #{agg.name}"))

          id = @last_submitted_id
          next unless id

          # Verify default state on show page
          results << check_show_contains("/#{plural}/show?id=#{id}",
            lc.default, "#{agg.name} default state '#{lc.default}'")

          expected_events = [create_cmd.inferred_event_name]
          current_state = lc.default

          # Walk transitions in order, respecting from: constraints
          walk_transitions(results, agg, lc, plural, id, expected_events, current_state)

          # Verify all lifecycle events in event log
          results << check_events_contain(expected_events, "#{agg.name} lifecycle events")
        end
      end

      def walk_transitions(results, agg, lc, plural, id, expected_events, current_state)
        lc.transitions.each do |cmd_name, _target|
          tcmd = agg.commands.find { |c| c.name == cmd_name }
          next unless tcmd
          target = lc.target_for(cmd_name)
          from = lc.from_for(cmd_name)

          # Skip if current state doesn't match the from: constraint
          next if from && (from.is_a?(Array) ? !from.include?(current_state) : from != current_state)

          tcmd_snake = underscore(tcmd.name)
          form_path = "/#{plural}/#{tcmd_snake}/new?id=#{id}"
          results.concat(submit_form(form_path, tcmd, "lifecycle #{cmd_name}"))

          # Verify show page reflects the state change
          results << check_show_contains("/#{plural}/show?id=#{id}",
            target, "#{agg.name} state '#{target}' after #{cmd_name}")

          expected_events << tcmd.inferred_event_name
          current_state = target
        end
      end
    end
  end
end
