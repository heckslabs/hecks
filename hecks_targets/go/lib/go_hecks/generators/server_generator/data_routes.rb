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

        cols = attrs.map { |a|
          lbl = dc.reference_attr?(a) ? dc.reference_column_label(a) : HecksTemplating::UILabelContract.label(a.name)
          "{Label: \"#{lbl}\"}"
        }
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

        ref_attrs = attrs.select { |a| dc.reference_attr?(a) }
        ref_lookups = ref_attrs.map { |a|
          ref_agg = dc.find_referenced_aggregate(a, @domain)
          [a, ref_agg]
        }.select { |_, ra| ra }

        cell_exprs = attrs.map { |a|
          ref_pair = ref_lookups.find { |ra, _| ra == a }
          if ref_pair
            ref_agg = ref_pair[1]
            field = GoUtils.pascal_case(a.name)
            map_name = "#{GoUtils.snake_case(ref_agg.name)}Names"
            "func() string { if n, ok := #{map_name}[obj.#{field}]; ok { return n }; if len(obj.#{field}) > 8 { return obj.#{field}[:8]+\"...\" }; return obj.#{field} }()"
          else
            dc.cell_expression(a, "obj", lang: :go)
          end
        }
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
        ref_lookups.each do |_, ref_agg|
          map_name = "#{GoUtils.snake_case(ref_agg.name)}Names"
          lines << "\t\t#{GoUtils.snake_case(ref_agg.name)}All, _ := app.#{ref_agg.name}Repo.All()"
          lines << "\t\t#{map_name} := map[string]string{}"
          lines << "\t\tfor _, m := range #{GoUtils.snake_case(ref_agg.name)}All { if m.Name != \"\" { #{map_name}[m.ID] = m.Name } else { #{map_name}[m.ID] = m.ID } }"
        end
        lines << "\t\tvar rows []#{safe}IndexItem"
        lines << "\t\tfor _, obj := range items {"
        lines << "\t\t\t#{vc.go_short_id('obj.ID')}"
        lines << "\t\t\tbaseActions := []RowAction{#{row_acts.join(', ')}}"
        lines << "\t\t\tactions := make([]RowAction, len(baseActions))"
        lines << "\t\t\tfor i, a := range baseActions { actions[i] = RowAction{Label: a.Label, HrefPrefix: a.HrefPrefix, Id: obj.ID, Allowed: a.Allowed, Direct: a.Direct, IdField: a.IdField} }"
        lines << "\t\t\trows = append(rows, #{safe}IndexItem{Id: obj.ID, ShortId: sid, ShowHref: \"/#{plural}/show?id=\"+obj.ID, Cells: []string{#{cell_exprs.join(', ')}}, RowActions: actions})"
        lines << "\t\t}"
        lines << "\t\trenderer.Render(w, \"index\", \"#{safe}s\", #{safe}IndexData{AggregateName: \"#{safe}\", Description: \"#{desc}\", CsrfToken: csrfToken(w, r), Items: rows, Columns: []#{safe}Column{#{cols.join(', ')}}, Buttons: []#{safe}Button{#{btns.join(', ')}}, RowActions: []RowAction{#{row_acts.join(', ')}}})"
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
        ac = HecksTemplating::AggregateContract
        cmd_snake = GoUtils.snake_case(cmd.name)
        agg_snake = GoUtils.snake_case(safe)
        agg = @domain.aggregates.find { |a| a.name == safe }
        lines = []
        lines << "\tmux.HandleFunc(\"POST #{HecksTemplating::RouteContract.submit_path(plural, cmd_snake)}\", func(w http.ResponseWriter, r *http.Request) {"
        lines << "\t\tvar cmd domain.#{cmd.name}"
        lines << "\t\tif r.Header.Get(\"Content-Type\") == \"application/json\" {"
        lines << "\t\t\tif err := json.NewDecoder(r.Body).Decode(&cmd); err != nil { http.Error(w, `{\"error\":\"invalid json\"}`, 400); return }"
        lines << "\t\t} else {"
        lines << "\t\t\tr.ParseForm()"
        lines << "\t\t\tif !validateCSRF(w, r) { return }"
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
        lines.concat(build_form_fields_go(cmd, agg, agg_snake, value_source: :form).map { |l| "\t" + l })
        lines << "\t\t\tw.WriteHeader(422)"
        lines << "\t\t\trenderer.Render(w, \"form\", \"#{cmd.name}\", FormData{"
        lines << "\t\t\t\tCommandName: \"#{HecksTemplating::UILabelContract.label(cmd.name)}\","
        lines << "\t\t\t\tAction: \"/#{plural}/#{cmd_snake}\","
        lines << "\t\t\t\tErrorMessage: err.Error(),"
        lines << "\t\t\t\tFields: fields,"
        lines << "\t\t\t\tCsrfToken: csrfToken(w, r),"
        lines << "\t\t\t}); return"
        lines << "\t\t}"
        lines << "\t\tif r.Header.Get(\"Content-Type\")==\"application/json\" { w.WriteHeader(201); jsonResponse(w, agg) } else {"
        lines << "\t\t\thttp.Redirect(w, r, \"/#{plural}/show?id=\"+agg.ID, http.StatusSeeOther)"
        lines << "\t\t}"
        lines << "\t})"
        lines << ""
        lines
      end

    end
  end
end
