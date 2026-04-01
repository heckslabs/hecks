
module Hecks
  module HTTP
    class MultiDomainServer
      # Hecks::HTTP::MultiDomainServer::UIRoutes
      #
      # UI route handlers for the multi-domain web explorer. Renders ERB
      # views for index, show, form, and submit routes, scoped by domain.
      # Extracted from MultiDomainServer to stay under the 200-line limit.
      #
      module UIRoutes
        include HecksTemplating::NamingHelpers
        private

        def serve_ui_route(req, res, entry, sub_path)
          domain = entry[:domain]
          mod = entry[:mod]
          slug = entry[:slug]

          agg = domain.aggregates.find { |a| sub_path.start_with?("/#{plural(a)}") }
          unless agg
            res.status = 404; res.body = "Not found"; return
          end

          safe = domain_constant_name(agg.name)
          klass = mod.const_get(safe)
          p = plural(agg)
          prefix = "/#{slug}"
          remaining = sub_path.sub("/#{p}", "")

          if remaining == "" || remaining == "/"
            serve_index(res, agg, klass, safe, p, prefix, domain)
          elsif remaining == "/show"
            serve_show(req, res, agg, klass, safe, p, prefix, domain)
          elsif remaining =~ /\/(\w+)\/new$/
            serve_form(req, res, agg, klass, safe, p, prefix, $1)
          elsif remaining =~ /\/(\w+)\/submit$/
            serve_submit(req, res, agg, klass, safe, p, prefix, $1)
          else
            res.status = 404; res.body = "Not found"
          end
        end

        def serve_index(res, agg, klass, safe, p, prefix, domain)
          dc = HecksTemplating::DisplayContract
          user_attrs = agg.attributes.reject { |a| Hecks::Utils::RESERVED_AGGREGATE_ATTRS.include?(a.name.to_s) }
          items = klass.all.map do |obj|
            cells = user_attrs.map { |a|
              if dc.reference_attr?(a)
                ref_agg = dc.find_referenced_aggregate(a, domain)
                resolve_reference(obj, a, ref_agg, klass)
              else
                obj.send(a.name).to_s
              end
            }
            { id: obj.id, short_id: obj.id[0..7], show_href: "#{prefix}/#{p}/show?id=#{obj.id}", cells: cells }
          end
          columns = user_attrs.map { |a|
            lbl = dc.reference_attr?(a) ? dc.reference_column_label(a) : humanize(a.name)
            { label: lbl }
          }
          create_cmds = agg.commands.select { |c| c.name.start_with?("Create") }
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

        def serve_show(req, res, agg, klass, safe, p, prefix, domain)
          dc = HecksTemplating::DisplayContract
          obj = klass.find(req.query["id"])
          unless obj
            res.status = 404; res.body = "Not found"; return
          end
          user_attrs = agg.attributes.reject { |a| Hecks::Utils::RESERVED_AGGREGATE_ATTRS.include?(a.name.to_s) }
          fields = user_attrs.map { |a|
            lbl = dc.reference_attr?(a) ? dc.reference_column_label(a) : humanize(a.name)
            val = if dc.reference_attr?(a)
              ref_agg = dc.find_referenced_aggregate(a, domain)
              resolve_reference(obj, a, ref_agg, klass)
            else
              obj.send(a.name).to_s
            end
            { label: lbl, value: val }
          }
          html = @renderer.render(:show,
            title: "#{safe} — #{@brand}", brand: @brand, nav_items: @nav,
            aggregate_name: safe, back_href: "#{prefix}/#{p}",
            id: obj.id, fields: fields, buttons: [])
          res["Content-Type"] = "text/html"
          res.body = html
        end

        def serve_form(req, res, agg, klass, safe, p, prefix, cmd_snake)
          cmd = agg.commands.find { |c| domain_snake_name(c.name) == cmd_snake }
          unless cmd
            res.status = 404; res.body = "Command not found"; return
          end
          fields = cmd.attributes.map do |a|
            { type: :input, name: a.name.to_s, label: humanize(a.name),
              input_type: "text", step: false, required: false, value: req.query[a.name.to_s] || "" }
          end
          html = @renderer.render(:form,
            title: "#{cmd.name} — #{@brand}", brand: @brand, nav_items: @nav,
            command_name: HecksTemplating::UILabelContract.label(cmd.name),
            action: "#{prefix}/#{p}/#{cmd_snake}/submit",
            error_message: nil, fields: fields)
          res["Content-Type"] = "text/html"
          res.body = html
        end

        def serve_submit(req, res, agg, klass, safe, p, prefix, cmd_snake)
          cmd = agg.commands.find { |c| domain_snake_name(c.name) == cmd_snake }
          unless cmd
            res.status = 404; res.body = "Command not found"; return
          end
          mod = klass
          params = req.query
          method_name = domain_command_method(cmd.name, agg.name)
          attrs = cmd.attributes.each_with_object({}) { |a, h| h[a.name] = params[a.name.to_s] || "" }
          result = klass.send(method_name, **attrs)
          id = result.respond_to?(:aggregate) ? result.aggregate.id : result.id
          res.set_redirect(WEBrick::HTTPStatus::SeeOther, "#{prefix}/#{p}/show?id=#{id}")
        rescue => e
          fields = cmd.attributes.map do |a|
            { type: :input, name: a.name.to_s, label: humanize(a.name),
              input_type: "text", step: false, required: false, value: params[a.name.to_s] || "" }
          end
          html = @renderer.render(:form,
            title: "#{cmd.name} — #{@brand}", brand: @brand, nav_items: @nav,
            command_name: HecksTemplating::UILabelContract.label(cmd.name),
            action: "#{prefix}/#{p}/#{cmd_snake}/submit",
            error_message: e.message, fields: fields)
          res["Content-Type"] = "text/html"
          res.body = html
        end
        def resolve_reference(obj, attr, ref_agg, klass)
          raw = obj.send(attr.name).to_s
          return raw[0..7] + "..." unless ref_agg
          ref_const = domain_constant_name(ref_agg.name)
          mod = klass.is_a?(Module) ? klass.to_s.split("::")[0..-2].join("::") : nil
          ref_klass = mod ? Object.const_get("#{mod}::#{ref_const}") : Object.const_get(ref_const) rescue nil
          return raw[0..7] + "..." unless ref_klass
          found = ref_klass.all.find { |x| x.id == raw }
          found&.respond_to?(:name) ? found.name.to_s : raw[0..7] + "..."
        end
      end
    end
  end
end
