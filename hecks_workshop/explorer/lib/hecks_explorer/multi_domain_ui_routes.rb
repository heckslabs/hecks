
module Hecks
  module HTTP
    class MultiDomainServer
      # Hecks::HTTP::MultiDomainServer::UIRoutes
      #
      # UI route handlers for the multi-domain web explorer. Structural
      # discovery (columns, fields, buttons) comes from IRIntrospector.
      # Runtime data access (find, all, execute) goes through RuntimeBridge.
      # Extracted from MultiDomainServer to stay under the 200-line limit.
      #
      module UIRoutes
        include HecksTemplating::NamingHelpers
        private

        def serve_ui_route(req, res, entry, sub_path)
          ir = entry[:ir]
          bridge = entry[:bridge]
          slug = entry[:slug]

          agg = ir.domain.aggregates.find { |a| sub_path.start_with?("/#{plural(a)}") }
          unless agg
            res.status = 404; res.body = "Not found"; return
          end

          safe = domain_constant_name(agg.name)
          p = plural(agg)
          prefix = "/#{slug}"
          remaining = sub_path.sub("/#{p}", "")

          if remaining == "" || remaining == "/"
            serve_index(res, ir, bridge, agg, safe, p, prefix)
          elsif remaining == "/show"
            serve_show(req, res, ir, bridge, agg, safe, p, prefix)
          elsif remaining =~ /\/(\w+)\/new$/
            serve_form(req, res, ir, agg, safe, p, prefix, $1)
          elsif remaining =~ /\/(\w+)\/submit$/
            serve_submit(req, res, ir, bridge, agg, safe, p, prefix, $1)
          else
            res.status = 404; res.body = "Not found"
          end
        end

        def serve_index(res, ir, bridge, agg, safe, p, prefix)
          user_attrs = ir.user_attributes(agg)
          items = bridge.find_all(agg.name).map do |obj|
            cells = user_attrs.map { |a|
              if ir.reference_attr?(a)
                ref_agg = ir.find_referenced_aggregate(a)
                bridge.resolve_reference_display(obj, a, ref_agg&.name)
              else
                bridge.read_attribute(obj, a.name)
              end
            }
            id = bridge.read_id(obj)
            { id: id, short_id: id[0..7], show_href: "#{prefix}/#{p}/show?id=#{id}", cells: cells }
          end
          ir.computed_attributes(agg).each do |ca|
            items.each do |item|
              obj = bridge.find_by_id(agg.name, item[:id])
              item[:cells] << bridge.evaluate_computed(obj, ca.block) if obj
            end
          end
          columns = ir.columns_for(agg)
          create_cmds = ir.create_commands(agg)
          buttons = create_cmds.map do |c|
            cm = domain_snake_name(c.name)
            { label: HecksTemplating::UILabelContract.label(c.name), href: "#{prefix}/#{p}/#{cm}/new", allowed: true }
          end
          html = @renderer.render(:index,
            title: "#{safe}s — #{@brand}", brand: @brand, nav_items: @nav,
            aggregate_name: safe, items: items, columns: columns,
            buttons: buttons, row_actions: [])
          res["Content-Type"] = "text/html"
          res.body = html
        end

        def serve_show(req, res, ir, bridge, agg, safe, p, prefix)
          obj = bridge.find_by_id(agg.name, req.query["id"])
          unless obj
            res.status = 404; res.body = "Not found"; return
          end
          user_attrs = ir.user_attributes(agg)
          fields = user_attrs.map { |a|
            lbl = ir.field_label(a)
            val = if ir.reference_attr?(a)
              ref_agg = ir.find_referenced_aggregate(a)
              bridge.resolve_reference_display(obj, a, ref_agg&.name)
            else
              bridge.read_attribute(obj, a.name)
            end
            { label: lbl, value: val }
          }
          ir.computed_attributes(agg).each do |ca|
            fields << { label: "#{Hecks::Utils.humanize(Hecks::Utils.sanitize_constant(ca.name))} (computed)",
                        value: bridge.evaluate_computed(obj, ca.block) }
          end
          html = @renderer.render(:show,
            title: "#{safe} — #{@brand}", brand: @brand, nav_items: @nav,
            aggregate_name: safe, back_href: "#{prefix}/#{p}",
            id: bridge.read_id(obj), fields: fields, buttons: [])
          res["Content-Type"] = "text/html"
          res.body = html
        end

        def serve_form(req, res, ir, agg, safe, p, prefix, cmd_snake)
          cmd = ir.find_command(agg, cmd_snake)
          unless cmd
            res.status = 404; res.body = "Command not found"; return
          end
          fields = ir.command_fields(cmd, req.query)
          html = @renderer.render(:form,
            title: "#{cmd.name} — #{@brand}", brand: @brand, nav_items: @nav,
            command_name: HecksTemplating::UILabelContract.label(cmd.name),
            action: "#{prefix}/#{p}/#{cmd_snake}/submit",
            error_message: nil, fields: fields)
          res["Content-Type"] = "text/html"
          res.body = html
        end

        def serve_submit(req, res, ir, bridge, agg, safe, p, prefix, cmd_snake)
          cmd = ir.find_command(agg, cmd_snake)
          unless cmd
            res.status = 404; res.body = "Command not found"; return
          end
          params = req.query
          method_name = domain_command_method(cmd.name, agg.name)
          attrs = cmd.attributes.each_with_object({}) { |a, h| h[a.name] = params[a.name.to_s] || "" }
          id = bridge.execute_command(agg.name, method_name, attrs)
          res.set_redirect(WEBrick::HTTPStatus::SeeOther, "#{prefix}/#{p}/show?id=#{id}")
        rescue => e
          fields = ir.command_fields(cmd, params || {})
          html = @renderer.render(:form,
            title: "#{cmd.name} — #{@brand}", brand: @brand, nav_items: @nav,
            command_name: HecksTemplating::UILabelContract.label(cmd.name),
            action: "#{prefix}/#{p}/#{cmd_snake}/submit",
            error_message: e.message, fields: fields)
          res["Content-Type"] = "text/html"
          res.body = html
        end
      end
    end
  end
end
