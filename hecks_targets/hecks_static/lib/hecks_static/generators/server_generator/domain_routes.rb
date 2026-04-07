
# HecksStatic::ServerGenerator::DomainRoutes
#
# Generates query, scope, specification, and event log routes for the
# domain server. These routes expose domain behavior over HTTP so the
# smoke test can exercise every domain object against any target
# (Ruby or Go).
#
#   # Mixed into ServerGenerator:
#   lines.concat(domain_behavior_routes)
#
module HecksStatic
  class ServerGenerator < Hecks::Generator
    module DomainRoutes
      include HecksTemplating::NamingHelpers
      private

      def domain_behavior_routes
        lines = []
        lines.concat(reset_route)
        lines.concat(events_route)
        @domain.aggregates.each do |agg|
          safe = domain_constant_name(agg.name)
          snake = domain_snake_name(safe)
          plural = domain_aggregate_slug(agg.name)
          lines.concat(query_routes(agg, safe, plural))
          lines.concat(scope_routes(agg, safe, plural))
          lines.concat(specification_routes(agg, safe, plural))
        end
        lines.concat(view_routes)
        lines.concat(workflow_routes)
        lines.concat(service_routes)
        lines
      end

      def reset_route
        mod = domain_module_name(@domain.name)
        lines = []
        lines << "        server.mount_proc \"/_reset\" do |req, res|"
        lines << "          next unless req.request_method == \"POST\" || req.request_method == \"DELETE\""
        lines << "          #{mod}.boot"
        lines << "          res.set_redirect(WEBrick::HTTPStatus::SeeOther, \"/config\")"
        lines << "        end"
        lines << ""
        lines
      end

      def events_route
        mod = domain_module_name(@domain.name)
        mapper = HecksTemplating::EventLogContract.ruby_mapper(event_var: "e")
        [
          "        server.mount_proc \"/_events\" do |req, res|",
          "          events = #{mod}.events.map do |e|",
          "            #{mapper}",
          "          end",
          "          json_response(res, events)",
          "        end",
          ""
        ]
      end

      def query_routes(agg, safe, plural)
        lines = []
        agg.queries.each do |query|
          query_snake = domain_snake_name(query.name)
          lines << "        server.mount_proc \"/#{plural}/queries/#{query_snake}\" do |req, res|"
          lines << "          begin"
          if query.block.arity > 0
            lines << "            args = req.query.values"
            lines << "            results = #{safe}.#{query_snake}(*args)"
          else
            lines << "            results = #{safe}.#{query_snake}"
          end
          lines << "            json_response(res, results.map { |obj| aggregate_to_hash(obj) })"
          lines << "          rescue => e"
          lines << "            json_error(res, { error: e.class.name, message: e.message })"
          lines << "          end"
          lines << "        end"
          lines << ""
        end
        lines
      end

      def scope_routes(agg, safe, plural)
        lines = []
        agg.scopes.each do |scope|
          lines << "        server.mount_proc \"/#{plural}/scopes/#{scope.name}\" do |req, res|"
          lines << "          begin"
          if scope.callable?
            lines << "            args = req.query.values"
            lines << "            results = #{safe}.#{scope.name}(*args)"
          else
            lines << "            results = #{safe}.#{scope.name}"
          end
          lines << "            json_response(res, results.map { |obj| aggregate_to_hash(obj) })"
          lines << "          rescue => e"
          lines << "            json_error(res, { error: e.class.name, message: e.message })"
          lines << "          end"
          lines << "        end"
          lines << ""
        end
        lines
      end

      def view_routes
        mod = domain_module_name(@domain.name)
        lines = []
        @domain.views.each do |view|
          view_snake = domain_snake_name(view.name)
          lines << "        server.mount_proc \"/_views/#{view_snake}\" do |req, res|"
          lines << "          state = #{mod}::#{view.name}.current"
          lines << "          json_response(res, state)"
          lines << "        end"
          lines << ""
        end
        lines
      end

      def workflow_routes
        mod = domain_module_name(@domain.name)
        lines = []
        @domain.workflows.each do |wf|
          wf_snake = domain_snake_name(wf.name)
          lines << "        server.mount_proc \"/_workflows/#{wf_snake}\" do |req, res|"
          lines << "          begin"
          lines << "            attrs = parse_body(req)"
          lines << "            result = #{mod}.#{wf_snake}(**attrs)"
          lines << "            json_response(res, { result: result&.class&.name })"
          lines << "          rescue => e"
          lines << "            json_error(res, e)"
          lines << "          end"
          lines << "        end"
          lines << ""
        end
        lines
      end

      def service_routes
        mod = domain_module_name(@domain.name)
        lines = []
        @domain.services.each do |svc|
          svc_snake = domain_snake_name(svc.name)
          lines << "        server.mount_proc \"/_services/#{svc_snake}\" do |req, res|"
          lines << "          begin"
          lines << "            attrs = parse_body(req)"
          lines << "            results = #{mod}.#{svc_snake}(**attrs)"
          lines << "            json_response(res, { results: results&.size })"
          lines << "          rescue => e"
          lines << "            json_error(res, e)"
          lines << "          end"
          lines << "        end"
          lines << ""
        end
        lines
      end

      def specification_routes(agg, safe, plural)
        lines = []
        agg.specifications.each do |spec|
          spec_snake = domain_snake_name(spec.name)
          mod = domain_module_name(@domain.name)
          lines << "        server.mount_proc \"/#{plural}/specifications/#{spec_snake}\" do |req, res|"
          lines << "          begin"
          lines << "            obj = #{safe}.find(req.query[\"id\"])"
          lines << "            unless obj"
          lines << "              json_error(res, { error: \"NotFound\", message: \"#{safe} not found\" }, status: 404)"
          lines << "              next"
          lines << "            end"
          lines << "            spec_class = #{mod}::#{safe}::Specifications::#{spec.name}"
          lines << "            result = spec_class.satisfied_by?(obj)"
          lines << "            json_response(res, { specification: \"#{spec.name}\", satisfied: result })"
          lines << "          rescue => e"
          lines << "            json_error(res, { error: e.class.name, message: e.message })"
          lines << "          end"
          lines << "        end"
          lines << ""
        end
        lines
      end
    end
  end
end
