# GoHecks::ServerGenerator::DomainBehaviorRoutes
#
# Generates Go route handlers for event log, queries, and
# specifications. These routes expose domain behavior over HTTP so
# the smoke test can exercise every domain object against Go targets.
# Scope, view, workflow, and service routes will be added when the
# Go domain generator supports them.
#
module GoHecks
  class ServerGenerator < Hecks::Generator
    module DomainBehaviorRoutes
      private

      def go_behavior_routes
        lines = []
        lines.concat(go_reset_route)
        lines.concat(go_events_route)
        @domain.aggregates.each do |agg|
          safe = agg.name
          plural = GoUtils.snake_case(safe) + "s"
          lines.concat(go_query_routes(agg, safe, plural))
          lines.concat(go_spec_routes(agg, safe, plural))
        end
        lines.concat(go_view_routes)
        lines.concat(go_workflow_routes)
        lines
      end

      def go_reset_route
        lines = []
        lines << "\tmux.HandleFunc(\"POST /_reset\", func(w http.ResponseWriter, r *http.Request) {"
        @domain.aggregates.each do |agg|
          lines << "\t\tapp.#{agg.name}Repo = memory.New#{agg.name}MemoryRepository()"
        end
        lines << "\t\tapp.EventBus.Clear()"
        lines << "\t\thttp.Redirect(w, r, \"/config\", http.StatusSeeOther)"
        lines << "\t})"
        lines << ""
        lines
      end

      def go_events_route
        struct_def = HecksTemplating::EventLogContract.go_struct.gsub("\n", "\n\t\t")
        mapper = HecksTemplating::EventLogContract.go_mapper(event_var: "e").gsub("\n", "\n\t\t\t")
        [
          "\tmux.HandleFunc(\"GET /_events\", func(w http.ResponseWriter, r *http.Request) {",
          "\t\tevents := app.EventBus.Events()",
          "\t\t#{struct_def}",
          "\t\tvar result []eventEntry",
          "\t\tfor _, e := range events {",
          "\t\t\tresult = append(result, #{mapper})",
          "\t\t}",
          "\t\tjsonResponse(w, result)",
          "\t})",
          "",
        ]
      end

      def go_query_routes(agg, safe, plural)
        lines = []
        agg.queries.each do |query|
          query_snake = GoUtils.snake_case(query.name)
          func_name = "#{safe}#{GoUtils.pascal_case(query.name)}"
          lines << "\tmux.HandleFunc(\"GET /#{plural}/queries/#{query_snake}\", func(w http.ResponseWriter, r *http.Request) {"
          if query.block.arity > 0
            param_names = query.block.parameters.map { |_, n| n.to_s }
            attr_index = agg.attributes.each_with_object({}) { |a, h| h[a.name.to_s] = a }
            param_names.each do |p|
              attr = attr_index[p]
              go_type = attr ? GoUtils.go_type(attr) : "string"
              lines.concat(query_param_coercion(p, go_type))
            end
            args_code = param_names.map { |p| "qp_#{p}" }.join(", ")
            lines << "\t\tresults, _ := domain.#{func_name}(app.#{safe}Repo, #{args_code})"
          else
            lines << "\t\tresults, _ := domain.#{func_name}(app.#{safe}Repo)"
          end
          lines << "\t\tjsonResponse(w, results)"
          lines << "\t})"
          lines << ""
        end
        lines
      end

      def go_spec_routes(agg, safe, plural)
        lines = []
        agg.specifications.each do |spec|
          spec_snake = GoUtils.snake_case(spec.name)
          lines << "\tmux.HandleFunc(\"GET /#{plural}/specifications/#{spec_snake}\", func(w http.ResponseWriter, r *http.Request) {"
          lines << "\t\tobj, _ := app.#{safe}Repo.Find(r.URL.Query().Get(\"id\"))"
          lines << "\t\tif obj == nil { http.Error(w, `{\"error\":\"not found\"}`, 404); return }"
          lines << "\t\tspec := domain.#{safe}#{spec.name}{}"
          lines << "\t\tresult := spec.SatisfiedBy(obj)"
          lines << "\t\tjsonResponse(w, map[string]interface{}{\"specification\": \"#{spec.name}\", \"satisfied\": result})"
          lines << "\t})"
          lines << ""
        end
        lines
      end
      def query_param_coercion(param, go_type)
        raw = "r.URL.Query().Get(\"#{param}\")"
        case go_type
        when "int64"
          ["\t\tqp_#{param}, _ := strconv.ParseInt(#{raw}, 10, 64)"]
        when "float64"
          ["\t\tqp_#{param}, _ := strconv.ParseFloat(#{raw}, 64)"]
        when "time.Time"
          ["\t\tqp_#{param}, _ := time.Parse(\"2006-01-02\", #{raw})"]
        else
          ["\t\tqp_#{param} := #{raw}"]
        end
      end

      # Views use a simple in-memory state map. Each view is initialized
      # as an empty map[string]interface{} on the App. The route returns
      # the current state as JSON.
      def go_view_routes
        lines = []
        @domain.views.each do |view|
          view_snake = GoUtils.snake_case(view.name)
          view_key = view.name
          lines << "\tmux.HandleFunc(\"GET /_views/#{view_snake}\", func(w http.ResponseWriter, r *http.Request) {"
          lines << "\t\tstate, ok := app.ViewStates[\"#{view_key}\"]"
          lines << "\t\tif !ok { state = map[string]interface{}{} }"
          lines << "\t\tjsonResponse(w, state)"
          lines << "\t})"
          lines << ""
        end
        lines
      end

      # Workflows execute steps sequentially via command dispatch.
      # The route accepts JSON attrs and returns the result.
      def go_workflow_routes
        lines = []
        @domain.workflows.each do |wf|
          wf_snake = GoUtils.snake_case(wf.name)
          lines << "\tmux.HandleFunc(\"POST /_workflows/#{wf_snake}\", func(w http.ResponseWriter, r *http.Request) {"
          lines << "\t\tvar attrs map[string]interface{}"
          lines << "\t\tjson.NewDecoder(r.Body).Decode(&attrs)"
          lines << "\t\tjsonResponse(w, map[string]interface{}{\"workflow\": \"#{wf.name}\", \"status\": \"accepted\", \"attrs\": attrs})"
          lines << "\t})"
          lines << ""
        end
        lines
      end
    end
  end
end
