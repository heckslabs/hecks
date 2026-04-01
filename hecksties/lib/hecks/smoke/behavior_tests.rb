# HecksTemplating::SmokeTest::BehaviorTests
#
# Tests domain behavior over HTTP: queries, scopes, specifications,
# lifecycle transitions, and policy chains. Each method walks the
# domain IR and exercises the corresponding HTTP routes. Works
# identically against Ruby and Go servers.
#
module HecksTemplating
  class SmokeTest
    module BehaviorTests
      private

      def test_queries(results)
        @domain.aggregates.each do |agg|
          plural = underscore(agg.name) + "s"
          agg.queries.each do |query|
            query_snake = underscore(query.name)
            path = HecksTemplating::RouteContract.query_path(plural, query_snake)
            path += "?value=example" if query.block.arity > 0
            results << check_get(path, "#{agg.name} query #{query.name}")
          end
        end
      end

      def test_scopes(results)
        @domain.aggregates.each do |agg|
          plural = underscore(agg.name) + "s"
          agg.scopes.each do |scope|
            path = HecksTemplating::RouteContract.scope_path(plural, scope.name)
            path += "?value=example" if scope.callable?
            results << check_get(path, "#{agg.name} scope #{scope.name}")
          end
        end
      end

      def test_specifications(results)
        @domain.aggregates.each do |agg|
          plural = underscore(agg.name) + "s"
          id = fetch_first_id(plural)
          next unless id

          agg.specifications.each do |spec|
            spec_snake = underscore(spec.name)
            path = "#{HecksTemplating::RouteContract.spec_path(plural, spec_snake)}?id=#{id}"
            results << check_get(path, "#{agg.name} spec #{spec.name}")
          end
        end
      end

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

          # Verify all lifecycle events in event log
          results << check_events_contain(expected_events, "#{agg.name} lifecycle events")
        end
      end

      def test_negative_cases(results)
        @domain.aggregates.each do |agg|
          plural = underscore(agg.name) + "s"
          agg_snake = underscore(agg.name)
          create_cmds, _ = partition_commands(agg, agg_snake)

          # Submit form with all fields empty — browser user submits blank form
          create_cmds.each do |cmd|
            cmd_snake = underscore(cmd.name)
            form_path = "/#{plural}/#{cmd_snake}/new"
            # GET form, parse action, POST with empty values
            uri = URI("#{@base}#{form_path}")
            html = Net::HTTP.get(uri) rescue ""
            action = parse_form_action(html) || HecksTemplating::RouteContract.submit_path(plural, cmd_snake)
            post_uri = URI("#{@base}#{action}")
            res = Net::HTTP.post_form(post_uri, {})
            code = res.code.to_i
            # 422 or re-rendered form (200 with error) both count as pass
            if [200, 422].include?(code)
              results << Result.new(status: :pass, method: "POST", path: action,
                                   http_code: code)
            else
              results << Result.new(status: :fail, method: "POST", path: action,
                                   http_code: code, error: res.body&.slice(0, 200))
            end
          end
        end
      end

      def test_views(results)
        @domain.views.each do |view|
          view_snake = underscore(view.name)
          path = "/_views/#{view_snake}"
          results << check_get(path, "view #{view.name}")
        end
      end

      def test_workflows(results)
        @domain.workflows.each do |wf|
          wf_snake = underscore(wf.name)
          path = "/_workflows/#{wf_snake}"
          # Workflows need POST with attributes
          first_cmd = find_workflow_first_cmd(wf)
          data = first_cmd ? build_form_data(first_cmd) : {}
          results << check_post(path, data, "workflow #{wf.name}")
        end
      end

      def test_services(results)
        @domain.services.each do |svc|
          svc_snake = underscore(svc.name)
          path = "/_services/#{svc_snake}"
          data = svc.respond_to?(:attributes) ? build_service_data(svc) : {}
          results << check_post(path, data, "service #{svc.name}")
        end
      end

      # Returns the command that emits this event, or nil if it's
      # from another domain (cross-domain policy trigger).
      def find_command_by_event(event_name)
        @domain.aggregates.each do |agg|
          agg.commands.each_with_index do |cmd, i|
            return cmd if agg.events[i]&.name == event_name
          end
        end
        nil
      end

      def find_event_name(command_name)
        @domain.aggregates.each do |agg|
          agg.commands.each_with_index do |cmd, i|
            return agg.events[i]&.name if cmd.name == command_name
          end
        end
        nil
      end

      def find_workflow_first_cmd(wf)
        return nil if wf.steps.empty?
        cmd_name = wf.steps.first[:command] || wf.steps.first["command"]
        return nil unless cmd_name
        @domain.aggregates.each do |agg|
          cmd = agg.commands.find { |c| c.name == cmd_name }
          return cmd if cmd
        end
        nil
      end

      def build_service_data(svc)
        svc.attributes.each_with_object({}) { |a, h| h[a.name.to_s] = sample_value(a) }
      end
    end
  end
end
