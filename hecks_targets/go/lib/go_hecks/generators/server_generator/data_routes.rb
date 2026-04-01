# GoHecks::ServerGenerator::DataRoutes
#
# Generates Go route handlers for JSON API endpoints (index, find,
# POST commands) and HTML show pages. All display conventions
# come from contracts — no inline rendering logic.
#
module GoHecks
  class ServerGenerator < Hecks::Generator
    module DataRoutes
      private

      def json_routes
        lines = []
        @domain.aggregates.each do |agg|
          safe = agg.name
          plural = GoUtils.snake_case(safe) + "s"
          attrs = agg.attributes.reject { |a| Hecks::Utils::RESERVED_AGGREGATE_ATTRS.include?(a.name.to_s) }
          agg_snake = GoUtils.snake_case(safe)

          lines.concat(index_route(agg, safe, plural, attrs, agg_snake))
          lines.concat(find_route(safe, plural))
          agg.commands.each { |cmd| lines.concat(command_route(safe, plural, cmd)) }
        end
        lines
      end

      def index_route(agg, safe, plural, attrs, agg_snake)
        vc = HecksTemplating::ViewContract
        ac = HecksTemplating::AggregateContract
        dc = HecksTemplating::DisplayContract

        cols = attrs.map { |a| "{Label: \"#{HecksTemplating::UILabelContract.label(a.name)}\"}" }
        create_cmds, update_cmds = ac.partition_commands(agg)

        btns = create_cmds.map { |c|
          "{Label: \"#{HecksTemplating::UILabelContract.label(c.name)}\", Href: \"/#{plural}/#{GoUtils.snake_case(c.name)}/new\", Allowed: true}"
        }

        row_acts = update_cmds.map { |c|
          cm = GoUtils.snake_case(c.name)
          if ac.direct_action?(c, agg_snake)
            self_ref = ac.self_ref_attr(c, agg_snake)
            "{Label: \"#{HecksTemplating::UILabelContract.label(c.name)}\", HrefPrefix: \"/#{plural}/#{cm}\", Allowed: true, Direct: true, IdField: \"#{self_ref&.name}\"}"
          else
            "{Label: \"#{HecksTemplating::UILabelContract.label(c.name)}\", HrefPrefix: \"/#{plural}/#{cm}/new?id=\", Allowed: true}"
          end
        }

        cell_exprs = attrs.map { |a| dc.cell_expression(a, "obj", lang: :go) }
        desc = agg.description || ""

        lines = []
        lines << "\t#{vc.go_struct(:column, vc::INDEX[:structs][:column], prefix: safe)}"
        lines << "\t#{vc.go_struct(:index_item, vc::INDEX[:structs][:index_item], prefix: safe)}"
        lines << "\t#{vc.go_struct(:button, vc::INDEX[:structs][:button], prefix: safe)}"
        lines << "\t#{vc.go_struct(:index_data, vc::INDEX[:fields], prefix: safe)}"
        lines << "\tmux.HandleFunc(\"GET /#{plural}\", func(w http.ResponseWriter, r *http.Request) {"
        lines << "\t\tif r.Header.Get(\"Accept\") == \"application/json\" || r.URL.Query().Get(\"format\") == \"json\" {"
        lines << "\t\t\titems, _ := app.#{safe}Repo.All(); jsonResponse(w, items); return"
        lines << "\t\t}"
        lines << "\t\titems, _ := app.#{safe}Repo.All()"
        lines << "\t\tvar rows []#{safe}IndexItem"
        lines << "\t\tfor _, obj := range items {"
        lines << "\t\t\t#{vc.go_short_id('obj.ID')}"
        lines << "\t\t\tbaseActions := []RowAction{#{row_acts.join(', ')}}"
        lines << "\t\t\tactions := make([]RowAction, len(baseActions))"
        lines << "\t\t\tfor i, a := range baseActions { actions[i] = RowAction{Label: a.Label, HrefPrefix: a.HrefPrefix, Id: obj.ID, Allowed: a.Allowed, Direct: a.Direct, IdField: a.IdField} }"
        lines << "\t\t\trows = append(rows, #{safe}IndexItem{Id: obj.ID, ShortId: sid, ShowHref: \"/#{plural}/show?id=\"+obj.ID, Cells: []string{#{cell_exprs.join(', ')}}, RowActions: actions})"
        lines << "\t\t}"
        lines << "\t\trenderer.Render(w, \"index\", \"#{safe}s\", #{safe}IndexData{AggregateName: \"#{safe}\", Description: \"#{desc}\", Items: rows, Columns: []#{safe}Column{#{cols.join(', ')}}, Buttons: []#{safe}Button{#{btns.join(', ')}}, RowActions: []RowAction{#{row_acts.join(', ')}}})"
        lines << "\t})"
        lines << ""
        lines
      end

      def find_route(safe, plural)
        [
          "\tmux.HandleFunc(\"GET /#{plural}/find\", func(w http.ResponseWriter, r *http.Request) {",
          "\t\titem, _ := app.#{safe}Repo.Find(r.URL.Query().Get(\"id\"))",
          "\t\tif item == nil { http.Error(w, `{\"error\":\"not found\"}`, 404); return }",
          "\t\tjsonResponse(w, item)",
          "\t})",
          "",
        ]
      end

      def command_route(safe, plural, cmd)
        cmd_snake = GoUtils.snake_case(cmd.name)
        lines = []
        lines << "\tmux.HandleFunc(\"POST #{HecksTemplating::RouteContract.submit_path(plural, cmd_snake)}\", func(w http.ResponseWriter, r *http.Request) {"
        lines << "\t\tvar cmd domain.#{cmd.name}"
        lines << "\t\tif r.Header.Get(\"Content-Type\") == \"application/json\" {"
        lines << "\t\t\tif err := json.NewDecoder(r.Body).Decode(&cmd); err != nil { http.Error(w, `{\"error\":\"invalid json\"}`, 400); return }"
        lines << "\t\t} else {"
        lines << "\t\t\tr.ParseForm()"
        cmd.attributes.each do |a|
          field = GoUtils.pascal_case(a.name)
          go_type = GoUtils.go_type(a)
          lines << "\t\t\t#{HecksTemplating::FormParsingContract.go_parse_line(a.name, field, go_type)}"
        end
        lines << "\t\t}"
        lines << "\t\tagg, event, err := cmd.Execute(app.#{safe}Repo)"
        lines << "\t\tif event != nil { app.EventBus.Publish(event) }"
        lines << "\t\tif err != nil {"
        lines << "\t\t\tif r.Header.Get(\"Content-Type\")==\"application/json\" { jsonError(w, err); return }"
        lines << "\t\t\thttp.Error(w, err.Error(), 422); return"
        lines << "\t\t}"
        lines << "\t\tif r.Header.Get(\"Content-Type\")==\"application/json\" { w.WriteHeader(201); jsonResponse(w, agg) } else {"
        lines << "\t\t\thttp.Redirect(w, r, \"/#{plural}/show?id=\"+agg.ID, http.StatusSeeOther)"
        lines << "\t\t}"
        lines << "\t})"
        lines << ""
        lines
      end

      def html_routes
        vc = HecksTemplating::ViewContract
        ac = HecksTemplating::AggregateContract
        dc = HecksTemplating::DisplayContract
        lines = []

        @domain.aggregates.each do |agg|
          safe = agg.name
          plural = GoUtils.snake_case(safe) + "s"
          agg_snake = GoUtils.snake_case(safe)
          attrs = agg.attributes.reject { |a| Hecks::Utils::RESERVED_AGGREGATE_ATTRS.include?(a.name.to_s) }

          lines << "\t#{vc.go_struct(:show_field, vc::SHOW[:structs][:show_field], prefix: safe)}"
          lines << "\t#{vc.go_struct(:show_data, vc::SHOW[:fields], prefix: safe)}"
          lines << "\tmux.HandleFunc(\"GET /#{plural}/show\", func(w http.ResponseWriter, r *http.Request) {"
          lines << "\t\tobj, _ := app.#{safe}Repo.Find(r.URL.Query().Get(\"id\"))"
          lines << "\t\tif obj == nil { http.Error(w, \"Not found\", 404); return }"
          lines << "\t\tfields := []#{safe}ShowField{"

          lc = agg.lifecycle
          lc_field = lc&.field&.to_s
          attrs.each do |a|
            field = GoUtils.pascal_case(a.name)
            label = HecksTemplating::UILabelContract.label(a.name)
            if a.list?
              lines << "\t\t\t{Label: \"#{label}\", Type: \"list\", Items: func() []string { var s []string; for _, v := range obj.#{field} { s = append(s, fmt.Sprintf(\"%v\", v)) }; return s }()},"
            elsif lc_field && a.name.to_s == lc_field
              transitions = dc.lifecycle_transitions(lc)
              trans_go = transitions.map { |t| "\"#{t}\"" }.join(", ")
              lines << "\t\t\t{Label: \"#{label}\", Type: \"lifecycle\", Value: fmt.Sprintf(\"%v\", obj.#{field}), Transitions: []string{#{trans_go}}},"
            else
              lines << "\t\t\t{Label: \"#{label}\", Value: fmt.Sprintf(\"%v\", obj.#{field})},"
            end
          end
          lines << "\t\t}"

          # Update command buttons — from contract
          _, update_cmds = ac.partition_commands(agg)
          if update_cmds.any?
            btn_exprs = update_cmds.map { |c|
              cm = GoUtils.snake_case(c.name)
              if ac.direct_action?(c, agg_snake)
                self_ref = ac.self_ref_attr(c, agg_snake)
                "#{safe}Button{Label: \"#{HecksTemplating::UILabelContract.label(c.name)}\", Href: \"/#{plural}/#{cm}\", Allowed: true, Direct: true, IdField: \"#{self_ref.name}\"}"
              else
                "#{safe}Button{Label: \"#{HecksTemplating::UILabelContract.label(c.name)}\", Href: \"/#{plural}/#{cm}/new?id=\" + obj.ID, Allowed: true}"
              end
            }
            lines << "\t\tbuttons := []#{safe}Button{#{btn_exprs.join(', ')}}"
          else
            lines << "\t\tvar buttons []#{safe}Button"
          end

          lines << "\t\trenderer.Render(w, \"show\", \"#{safe}\", #{safe}ShowData{AggregateName: \"#{safe}\", BackHref: \"/#{plural}\", Id: obj.ID, Fields: fields, Buttons: buttons})"
          lines << "\t})"
          lines << ""
        end
        lines
      end
    end
  end
end
