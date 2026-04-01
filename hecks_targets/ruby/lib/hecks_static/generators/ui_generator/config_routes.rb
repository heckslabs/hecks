# HecksStatic::UIGenerator::ConfigRoutes
#
# Generates the /config page route. Uses DisplayContract for
# aggregate summaries, policy labels, and role extraction.
#
module HecksStatic
  class UIGenerator < Hecks::Generator
    module ConfigRoutes
      include HecksTemplating::NamingHelpers
      private

      def config_route(mod)
        dc = HecksTemplating::DisplayContract

        agg_rows = @domain.aggregates.map do |agg|
          safe = domain_constant_name(agg.name)
          summary = dc.aggregate_summary(agg)
          "{ name: \"#{safe}\", href: \"/#{plural(agg)}\", count: #{safe}.count, commands: \"#{summary[:commands]}\", ports: \"#{summary[:ports]}\" }"
        end

        policies = dc.policy_labels(@domain)
        diagrams = generate_diagrams

        [
          "        server.mount_proc \"/config\" do |req, res|",
          "          next unless req.request_method == \"GET\"",
          "          cfg = #{mod}.config || {}",
          "          html = renderer.render(:config, title: \"Config — #{mod}\", brand: brand, nav_items: nav,",
          "            roles: #{mod}::ROLES, current_role: #{mod}.current_role.to_s,",
          "            adapters: %w[memory filesystem sqlite], current_adapter: cfg[:adapter].to_s,",
          "            event_count: #{mod}.events.size, booted_at: (cfg[:booted_at] || \"unknown\").to_s,",
          "            policies: #{policies.inspect},",
          "            aggregates: [#{agg_rows.join(', ')}],",
          "            structure_diagram: #{diagrams[:structure].inspect},",
          "            behavior_diagram: #{diagrams[:behavior].inspect},",
          "            flows_diagram: #{diagrams[:flows].inspect})",
          "          res[\"Content-Type\"] = \"text/html\"; res.body = html",
          "        end",
          ""
        ]
      end

      def generate_diagrams
        vis = Hecks::DomainVisualizer.new(@domain)
        {
          structure: vis.generate_structure,
          behavior: vis.generate_behavior,
          flows: Hecks::FlowGenerator.new(@domain).generate_mermaid
        }
      end

      def reboot_route(mod)
        [
          "        server.mount_proc \"/config/reboot\" do |req, res|",
          "          adapter = (req.query[\"adapter\"] || \"memory\").to_sym",
          "          #{mod}.reboot(adapter: adapter)",
          "          res.set_redirect(WEBrick::HTTPStatus::SeeOther, \"/config\")",
          "        end",
          "",
          "        server.mount_proc \"/config/role\" do |req, res|",
          "          #{mod}.current_role = req.query[\"role\"] || #{mod}.current_role",
          "          res.set_redirect(WEBrick::HTTPStatus::SeeOther, \"/config\")",
          "        end",
          ""
        ]
      end
    end
  end
end
