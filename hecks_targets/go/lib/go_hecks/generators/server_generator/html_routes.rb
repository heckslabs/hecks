# GoHecks::ServerGenerator::HtmlRoutes
#
# Generates Go HTML show page routes for aggregates. Renders field
# labels, values, lifecycle states, and reference lookups (entity
# name instead of raw UUID). Extracted from DataRoutes.
#
module GoHecks
  class ServerGenerator < Hecks::Generator
    module HtmlRoutes
      private

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

          ref_attrs = attrs.select { |a| dc.reference_attr?(a) }
          show_ref_lookups = ref_attrs.map { |a| [a, dc.find_referenced_aggregate(a, @domain)] }.select { |_, ra| ra }

          lines << "\t#{vc.go_struct(:show_field, vc::SHOW[:structs][:show_field], prefix: safe)}"
          lines << "\t#{vc.go_struct(:show_data, vc::SHOW[:fields], prefix: safe)}"
          lines << "\tmux.HandleFunc(\"GET /#{plural}/show\", func(w http.ResponseWriter, r *http.Request) {"
          lines << "\t\tobj, _ := app.#{safe}Repo.Find(r.URL.Query().Get(\"id\"))"
          lines << "\t\tif obj == nil { http.Error(w, \"Not found\", 404); return }"
          show_ref_lookups.each do |_, ref_agg|
            map_name = "#{GoUtils.snake_case(ref_agg.name)}Names"
            lines << "\t\t#{GoUtils.snake_case(ref_agg.name)}All, _ := app.#{ref_agg.name}Repo.All()"
            lines << "\t\t#{map_name} := map[string]string{}"
            lines << "\t\tfor _, m := range #{GoUtils.snake_case(ref_agg.name)}All { if m.Name != \"\" { #{map_name}[m.ID] = m.Name } else { #{map_name}[m.ID] = m.ID } }"
          end
          lines << "\t\tfields := []#{safe}ShowField{"

          lc = agg.lifecycle
          lc_field = lc&.field&.to_s
          attrs.each do |a|
            field = GoUtils.pascal_case(a.name)
            label = dc.reference_attr?(a) ? dc.reference_column_label(a) : HecksTemplating::UILabelContract.label(a.name)
            if a.list?
              lines << "\t\t\t{Label: \"#{label}\", Type: \"list\", Items: func() []string { var s []string; for _, v := range obj.#{field} { s = append(s, fmt.Sprintf(\"%v\", v)) }; return s }()},"
            elsif lc_field && a.name.to_s == lc_field
              transitions = dc.lifecycle_transitions(lc)
              trans_go = transitions.map { |t| "\"#{t}\"" }.join(", ")
              lines << "\t\t\t{Label: \"#{label}\", Type: \"lifecycle\", Value: fmt.Sprintf(\"%v\", obj.#{field}), Transitions: []string{#{trans_go}}},"
            elsif dc.reference_attr?(a)
              ref_pair = show_ref_lookups.find { |ra, _| ra == a }
              if ref_pair
                map_name = "#{GoUtils.snake_case(ref_pair[1].name)}Names"
                lines << "\t\t\t{Label: \"#{label}\", Value: func() string { if n, ok := #{map_name}[obj.#{field}]; ok { return n }; if len(obj.#{field}) > 8 { return obj.#{field}[:8]+\"...\" }; return obj.#{field} }()},"
              else
                lines << "\t\t\t{Label: \"#{label}\", Value: func() string { if len(obj.#{field}) > 8 { return obj.#{field}[:8]+\"...\" }; return obj.#{field} }()},"
              end
            else
              lines << "\t\t\t{Label: \"#{label}\", Value: fmt.Sprintf(\"%v\", obj.#{field})},"
            end
          end
          lines << "\t\t}"

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

          # Cross-aggregate command buttons
          @domain.aggregates.each do |other|
            next if other.name == agg.name
            other_snake = GoUtils.snake_case(other.name)
            other_plural = other_snake + "s"
            other.commands.each do |cmd|
              snake = GoUtils.snake_case(agg.name)
              has_ref = (cmd.references || []).any? { |r| Hecks::Utils.underscore(r.type) == snake }
              has_attr = cmd.attributes.any? { |a| a.name.to_s == "#{snake}_id" }
              next unless has_ref || has_attr
              cm = GoUtils.snake_case(cmd.name)
              label = HecksTemplating::UILabelContract.label(cmd.name)
              lines << "\t\tbuttons = append(buttons, #{safe}Button{Label: \"#{label}\", Href: \"/#{other_plural}/#{cm}/new?id=\" + obj.ID, Allowed: true})"
            end
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
