
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
            serve_index(req, res, agg, klass, safe, p, prefix, domain)
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

        def serve_index(req, res, agg, klass, safe, p, prefix, domain)
          token = ensure_csrf_cookie(req, res)
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
          computed = agg.computed_attributes || []
          computed.each do |ca|
            items.each do |item|
              obj = klass.find(item[:id])
              item[:cells] << obj.instance_eval(&ca.block).to_s if obj
            end
          end
          columns = user_attrs.map { |a|
            lbl = dc.reference_attr?(a) ? dc.reference_column_label(a) : humanize(a.name)
            { label: lbl }
          }
          computed.each { |ca| columns << { label: "#{humanize(ca.name)} (computed)" } }
          create_cmds = agg.commands.select { |c| c.name.start_with?("Create") }
          buttons = create_cmds.map do |c|
            cm = domain_snake_name(c.name)
            { label: HecksTemplating::UILabelContract.label(c.name), href: "#{prefix}/#{p}/#{cm}/new", allowed: true }
          end
          html = @renderer.render(:index,
            title: "#{safe}s — #{@brand}", brand: @brand, nav_items: @nav,
            aggregate_name: safe, items: items, columns: columns,
            buttons: buttons, row_actions: [], csrf_token: token)
          res["Content-Type"] = "text/html"
          res.body = html
        end

        def serve_show(req, res, agg, klass, safe, p, prefix, domain)
          token = ensure_csrf_cookie(req, res)
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
          (agg.computed_attributes || []).each do |ca|
            fields << { label: "#{humanize(ca.name)} (computed)", value: obj.instance_eval(&ca.block).to_s }
          end
          html = @renderer.render(:show,
            title: "#{safe} — #{@brand}", brand: @brand, nav_items: @nav,
            aggregate_name: safe, back_href: "#{prefix}/#{p}",
            id: obj.id, fields: fields, buttons: [], csrf_token: token)
          res["Content-Type"] = "text/html"
          res.body = html
        end

        def serve_form(req, res, agg, klass, safe, p, prefix, cmd_snake)
          token = ensure_csrf_cookie(req, res)
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
            error_message: nil, fields: fields, csrf_token: token)
          res["Content-Type"] = "text/html"
          res.body = html
        end

        def serve_submit(req, res, agg, klass, safe, p, prefix, cmd_snake)
          unless valid_csrf?(req)
            res.status = 403; res.body = "Forbidden: CSRF token mismatch"; return
          end
          cmd = agg.commands.find { |c| domain_snake_name(c.name) == cmd_snake }
          unless cmd
            res.status = 404; res.body = "Command not found"; return
          end
          params = req.query
          method_name = domain_command_method(cmd.name, agg.name)
          attrs = cmd.attributes.each_with_object({}) { |a, h| h[a.name] = params[a.name.to_s] || "" }
          result = klass.send(method_name, **attrs)
          id = result.respond_to?(:aggregate) ? result.aggregate.id : result.id
          res.set_redirect(WEBrick::HTTPStatus::SeeOther, "#{prefix}/#{p}/show?id=#{id}")
        rescue => e
          token = read_csrf_cookie(req)
          fields = cmd.attributes.map do |a|
            { type: :input, name: a.name.to_s, label: humanize(a.name),
              input_type: "text", step: false, required: false, value: params[a.name.to_s] || "" }
          end
          html = @renderer.render(:form,
            title: "#{cmd.name} — #{@brand}", brand: @brand, nav_items: @nav,
            command_name: HecksTemplating::UILabelContract.label(cmd.name),
            action: "#{prefix}/#{p}/#{cmd_snake}/submit",
            error_message: e.message, fields: fields, csrf_token: token)
          res["Content-Type"] = "text/html"
          res.body = html
        end

        def ensure_csrf_cookie(req, res)
          existing = read_csrf_cookie(req)
          return existing if existing && !existing.empty?
          token = Hecks::Conventions::CsrfContract.generate_token
          res["Set-Cookie"] = Hecks::Conventions::CsrfContract.cookie_header(token)
          token
        end

        def read_csrf_cookie(req)
          cookie_header = req["Cookie"] || ""
          name = Hecks::Conventions::CsrfContract::COOKIE_NAME
          match = cookie_header.match(/(?:^|;\s*)#{Regexp.escape(name)}=([^;]+)/)
          match ? match[1] : nil
        end

        def valid_csrf?(req)
          cookie_val = read_csrf_cookie(req)
          form_val = req.query[Hecks::Conventions::CsrfContract::FIELD_NAME]
          Hecks::Conventions::CsrfContract.valid?(cookie_val, form_val)
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
