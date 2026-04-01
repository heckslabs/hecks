# GoHecks::ServerGenerator::UIRoutes
#
# Generates Go route handlers for form pages and the config page.
# All display conventions come from contracts.
#
module GoHecks
  class ServerGenerator < Hecks::Generator
    module UIRoutes
      private

      def form_routes
        ac = HecksTemplating::AggregateContract
        lines = []
        lines << "\t// Form routes (types in renderer.go)"

        @domain.aggregates.each do |agg|
          safe = agg.name
          plural = GoUtils.snake_case(safe) + "s"
          agg_snake = GoUtils.snake_case(safe)

          agg.commands.each do |cmd|
            cmd_snake = GoUtils.snake_case(cmd.name)

            lines << "\tmux.HandleFunc(\"GET #{HecksTemplating::RouteContract.form_path(plural, cmd_snake)}\", func(w http.ResponseWriter, r *http.Request) {"
            lines.concat(build_form_fields_go(cmd, agg, agg_snake, value_source: :query))

            lines << "\t\trenderer.Render(w, \"form\", \"#{cmd.name}\", FormData{"
            lines << "\t\t\tCommandName: \"#{HecksTemplating::UILabelContract.label(cmd.name)}\","
            lines << "\t\t\tAction: \"#{HecksTemplating::RouteContract.submit_path(plural, cmd_snake)}\","
            lines << "\t\t\tFields: fields,"
            lines << "\t\t})"
            lines << "\t})"
            lines << ""
          end
        end
        lines
      end

      def build_form_fields_go(cmd, agg, agg_snake, value_source: :query)
        ac = HecksTemplating::AggregateContract
        self_id = ac.self_ref_attr(cmd, agg_snake)
        lines = []
        lines << "\t\tfields := []FormField{"
        cmd.attributes.each do |a|
          if a == self_id
            id_val = value_source == :form ? "r.FormValue(\"#{a.name}\")" : "r.URL.Query().Get(\"id\")"
            lines << "\t\t\t{Type: \"hidden\", Name: \"#{a.name}\", Value: #{id_val}},"
          else
            agg_attr = agg.attributes.find { |aa| aa.name == a.name }
            enum_values = agg_attr&.enum
            label = HecksTemplating::UILabelContract.label(a.name)
            if enum_values && !enum_values.empty?
              opts = enum_values.map { |v| "FormOption{Value: \"#{v}\", Label: \"#{v}\"}" }.join(", ")
              lines << "\t\t\t{Type: \"select\", Name: \"#{a.name}\", Label: \"#{label}\", Required: true, Options: []FormOption{#{opts}}},"
            else
              go_type = GoUtils.go_type(a)
              input_type = HecksTemplating::FormParsingContract.input_type(go_type)
              step = HecksTemplating::FormParsingContract.step?(go_type) ? ", Step: true" : ""
              val = value_source == :form ? ", Value: r.FormValue(\"#{a.name}\")" : ""
              lines << "\t\t\t{Type: \"input\", Name: \"#{a.name}\", Label: \"#{label}\", InputType: \"#{input_type}\", Required: true#{step}#{val}},"
            end
          end
        end
        # Reference dropdowns (placeholders, built dynamically below)
        (cmd.references || []).each do |ref|
          lines << "\t\t\t// #{ref.type} dropdown built dynamically below"
        end
        lines << "\t\t}"

        # Build dropdowns for reference fields
        (cmd.references || []).each do |ref|
          ref_agg = @domain.aggregates.find { |ra| ra.name == ref.type }
          next unless ref_agg
          ref_safe = ref_agg.name
          display = HecksTemplating::DisplayContract.go_reference_display_field(ref_agg)
          label = HecksTemplating::UILabelContract.label(ref.name.to_s)
          selected_expr = value_source == :form \
            ? "item.ID == r.FormValue(\"#{ref.name}\")" \
            : "item.ID == r.URL.Query().Get(\"id\")"
          lines << "\t\t#{ref_safe.downcase}s, _ := app.#{ref_safe}Repo.All()"
          lines << "\t\tvar #{ref_safe.downcase}Opts []FormOption"
          lines << "\t\tfor _, item := range #{ref_safe.downcase}s {"
          lines << "\t\t\t#{ref_safe.downcase}Opts = append(#{ref_safe.downcase}Opts, FormOption{Value: item.ID, Label: fmt.Sprintf(\"%v\", item.#{display}), Selected: #{selected_expr}})"
          lines << "\t\t}"
          lines << "\t\tfields = append(fields, FormField{Type: \"select\", Name: \"#{ref.name}\", Label: \"#{label}\", Required: true, Options: #{ref_safe.downcase}Opts})"
        end
        lines
      end

      def config_route
        dc = HecksTemplating::DisplayContract
        all_roles = dc.available_roles(@domain)
        policies = dc.policy_labels(@domain)
        diagrams = generate_diagrams

        vc = HecksTemplating::ViewContract
        lines = []
        lines << "\t// Config"
        lines << "\t#{vc.go_struct(:config_agg, vc::CONFIG[:structs][:config_agg])}"
        lines << "\t#{vc.go_struct(:config_data, vc::CONFIG[:fields])}"
        lines << "\tcurrentRole := \"#{all_roles.first}\""
        lines << "\tmux.HandleFunc(\"GET /config\", func(w http.ResponseWriter, r *http.Request) {"
        lines << "\t\taggs := []ConfigAgg{"
        @domain.aggregates.each do |agg|
          plural = GoUtils.snake_case(agg.name) + "s"
          summary = dc.aggregate_summary(agg)
          lines << "\t\t\t{Name: \"#{agg.name}\", Href: \"/#{plural}\", Commands: \"#{summary[:commands]}\", Ports: \"#{summary[:ports]}\"},"
        end
        lines << "\t\t}"
        @domain.aggregates.each_with_index do |agg, idx|
          lines << "\t\t#{agg.name.downcase}Count, _ := app.#{agg.name}Repo.Count()"
          lines << "\t\taggs[#{idx}].Count = #{agg.name.downcase}Count"
        end
        lines << "\t\trenderer.Render(w, \"config\", \"Config\", ConfigData{"
        lines << "\t\t\tRoles: []string{#{all_roles.map { |r| "\"#{r}\"" }.join(', ')}},"
        lines << "\t\t\tCurrentRole: currentRole,"
        lines << "\t\t\tAdapters: []string{\"memory\", \"filesystem\"},"
        lines << "\t\t\tCurrentAdapter: \"memory\","
        lines << "\t\t\tEventCount: len(app.EventBus.Events()),"
        lines << "\t\t\tBootedAt: \"running\","
        lines << "\t\t\tPolicies: []string{#{policies.map { |p| "\"#{p}\"" }.join(', ')}},"
        lines << "\t\t\tAggregates: aggs,"
        lines << "\t\t\tStructureDiagram: #{go_html_literal(diagrams[:structure])},"
        lines << "\t\t\tBehaviorDiagram: #{go_html_literal(diagrams[:behavior])},"
        lines << "\t\t\tFlowsDiagram: #{go_html_literal(diagrams[:flows])},"
        lines << "\t\t})"
        lines << "\t})"
        lines << ""
        lines
      end

      def generate_diagrams
        vis = Hecks::DomainVisualizer.new(@domain)
        {
          structure: vis.generate_structure,
          behavior: vis.generate_behavior,
          flows: Hecks::FlowGenerator.new(@domain).generate_mermaid
        }
      end

      def go_html_literal(str)
        "template.HTML(#{str.inspect})"
      end
    end
  end
end
