
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
        include CsrfHelpers
        private

        def serve_events_json(res)
          evts = @entries.flat_map { |e| e[:runtime].event_bus.events }
          res["Content-Type"] = "application/json"
          res.body = JSON.generate(evts.map { |e| { type: Hecks::Utils.const_short_name(e), occurred_at: (e.occurred_at.iso8601 rescue nil) } })
        end

        def serve_events(req, res)
          require "hecks/extensions/web_explorer/paginator"
          buses = @entries.map { |e| e[:runtime].event_bus }
          ei = Hecks::WebExplorer::EventIntrospector.new(buses)
          tf, af = req.query["type"].to_s, req.query["aggregate"].to_s
          all = ei.all_entries(type_filter: tf, aggregate_filter: af)
          pager = Hecks::WebExplorer::Paginator.new(all, page: (req.query["page"] || 1).to_i)
          items = pager.items.map { |e| format_event_entry(e) }
          base = [(tf.empty? ? nil : "type=#{tf}"), (af.empty? ? nil : "aggregate=#{af}")].compact
          html = @renderer.render(:events,
            title: "Events — #{@brand}", brand: @brand, nav_items: @nav,
            items: items, total_count: pager.total_count,
            event_types: ei.event_types, aggregate_types: ei.aggregate_types,
            type_filter: tf, aggregate_filter: af,
            current_page: pager.current, total_pages: pager.total_pages,
            prev_page: pager.previous_page, next_page_num: pager.next_page,
            page_query: ->(pg) { (base + ["page=#{pg}"]).join("&") })
          res["Content-Type"] = "text/html"; res.body = html
        end

        def format_event_entry(e)
          ts = e[:occurred_at] ? e[:occurred_at].strftime("%Y-%m-%d %H:%M:%S") : "—"
          e.merge(occurred_at_display: ts, payload_display: e[:payload].map { |k, v| "#{k}: #{v}" }.join("\n"))
        end

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
            serve_index(req, res, ir, bridge, agg, safe, p, prefix)
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

        def parse_search_params(req)
          q = req.query["q"].to_s.strip
          q = nil if q.empty?
          filters = {}
          req.query.each do |key, value|
            next unless key.start_with?("filter[") && key.end_with?("]")
            attr = key[7..-2]
            filters[attr.to_sym] = value unless value.to_s.strip.empty?
          end
          [q, filters]
        end

        def serve_index(req, res, ir, bridge, agg, safe, p, prefix)
          token = ensure_csrf_cookie(req, res)
          q, filters = parse_search_params(req)
          user_attrs = ir.user_attributes(agg)
          filterable = ir.filterable_attributes(agg).map(&:name)
          records = bridge.search_and_filter(agg.name, string_attr_names: filterable, query: q, filters: filters)
          items = records.map do |obj|
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
            buttons: buttons, row_actions: [], csrf_token: token,
            search_query: q.to_s, index_url: "#{prefix}/#{p}")
          res["Content-Type"] = "text/html"
          res.body = html
        end

        def serve_show(req, res, ir, bridge, agg, safe, p, prefix)
          token = ensure_csrf_cookie(req, res)
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
            id: bridge.read_id(obj), fields: fields, buttons: [], csrf_token: token)
          res["Content-Type"] = "text/html"
          res.body = html
        end

        def serve_form(req, res, ir, agg, safe, p, prefix, cmd_snake)
          token = ensure_csrf_cookie(req, res)
          cmd = ir.find_command(agg, cmd_snake)
          unless cmd
            res.status = 404; res.body = "Command not found"; return
          end
          fields = ir.command_fields(cmd, req.query)
          html = @renderer.render(:form,
            title: "#{cmd.name} — #{@brand}", brand: @brand, nav_items: @nav,
            command_name: HecksTemplating::UILabelContract.label(cmd.name),
            action: "#{prefix}/#{p}/#{cmd_snake}/submit",
            error_message: nil, fields: fields, csrf_token: token)
          res["Content-Type"] = "text/html"
          res.body = html
        end

        def serve_submit(req, res, ir, bridge, agg, safe, p, prefix, cmd_snake)
          unless valid_csrf?(req)
            res.status = 403; res.body = "Forbidden: CSRF token mismatch"; return
          end
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
          token = read_csrf_cookie(req)
          fields = ir.command_fields(cmd, params || {})
          html = @renderer.render(:form,
            title: "#{cmd.name} — #{@brand}", brand: @brand, nav_items: @nav,
            command_name: HecksTemplating::UILabelContract.label(cmd.name),
            action: "#{prefix}/#{p}/#{cmd_snake}/submit",
            error_message: e.message, fields: fields, csrf_token: token)
          res["Content-Type"] = "text/html"
          res.body = html
        end

        def valid_csrf?(req)
          return true if token_authenticated?(req)
          cookie_val = read_csrf_cookie(req)
          form_val = req.query[Hecks::Conventions::CsrfContract::FIELD_NAME]
          Hecks::Conventions::CsrfContract.valid?(cookie_val, form_val)
        end
      end
    end
  end
end
