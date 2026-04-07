# HecksStatic::UIGenerator::ShowRoute
#
# Generates the show route handler for an aggregate detail page.
# Renders field labels, values, lifecycle transitions, list items,
# and reference lookups (entity name instead of raw UUID).
#
#   lines = show_route(agg, "MyApp")
#
module HecksStatic
  class UIGenerator < Hecks::Generator
    module ShowRoute
      include HecksTemplating::NamingHelpers
      private

      def show_route(agg, mod)
        safe = domain_constant_name(agg.name)
        p = plural(agg)
        attrs = user_attrs(agg)
        agg_snake = domain_snake_name(agg.name)

        lc = agg.lifecycle
        lc_field = lc&.field&.to_s

        dc = HecksTemplating::DisplayContract
        field_exprs = attrs.map { |a| show_field_expr(a, agg, lc, lc_field, dc) }

        btn_parts = show_buttons(agg, mod, safe, p, agg_snake)

        [
          "        server.mount_proc \"/#{p}/show\" do |req, res|",
          "          obj = #{safe}.find(req.query[\"id\"])",
          "          unless obj",
          "            res.status = 404; res.body = \"Not found\"; next",
          "          end",
          "          html = renderer.render(:show, title: \"#{safe} — #{mod}\", brand: brand, nav_items: nav,",
          "            aggregate_name: \"#{safe}\", back_href: \"/#{p}\",",
          "            csrf_token: ensure_csrf_cookie(req, res),",
          "            id: obj.id, fields: [#{field_exprs.join(', ')}],",
          "            buttons: [#{btn_parts.join(', ')}])",
          "          res[\"Content-Type\"] = \"text/html\"; res.body = html",
          "        end",
          ""
        ]
      end

      def show_field_expr(a, agg, lc, lc_field, dc)
        label = dc.reference_attr?(a) ? dc.reference_column_label(a) : humanize(a.name)
        if a.list?
          show_list_field(a, agg, label)
        elsif lc_field && a.name.to_s == lc_field
          transitions = dc.lifecycle_transitions(lc)
          "{ label: \"#{label}\", type: :lifecycle, value: obj.#{a.name}.to_s, transitions: #{transitions.inspect} }"
        elsif dc.reference_attr?(a)
          show_reference_field(a, label, dc)
        else
          "{ label: \"#{label}\", value: obj.#{a.name}.to_s }"
        end
      end

      def show_list_field(a, agg, label)
        vo = agg.value_objects.find { |v| v.name == a.type.to_s }
        if vo
          vo_attrs = vo.attributes.map(&:name).map(&:to_s)
          items_expr = "obj.#{a.name}.map { |v| #{vo_attrs.map { |va| "v.#{va}.to_s" }.join(' + " — " + ')} }"
          "{ label: \"#{label}\", type: :list, items: #{items_expr} }"
        else
          "{ label: \"#{label}\", type: :list, items: obj.#{a.name}.map(&:to_s) }"
        end
      end

      def show_reference_field(a, label, dc)
        ref_agg = dc.find_referenced_aggregate(a, @domain)
        if ref_agg
          "{ label: \"#{label}\", value: (-> { _r = #{ref_agg.name}.all.find { |x| x.id == obj.#{a.name} }; _r&.respond_to?(:name) ? _r.name.to_s : obj.#{a.name}.to_s[0..7] + \"...\" }).call }"
        else
          "{ label: \"#{label}\", value: obj.#{a.name}.to_s[0..7] + \"...\" }"
        end
      end

      def show_buttons(agg, mod, safe, p, agg_snake)
        ac = HecksTemplating::AggregateContract
        btn_parts = []
        _, update_cmds = ac.partition_commands(agg)
        update_cmds.each do |c|
          cm = domain_snake_name(c.name)
          if ac.direct_action?(c, agg_snake)
            self_id = ac.self_ref_attr(c, agg_snake)
            btn_parts << "{ label: \"#{HecksTemplating::UILabelContract.label(c.name)}\", href: \"/#{p}/#{cm}/submit\", allowed: #{mod}.role_allows?(\"#{safe}\", \"#{cm}\"), direct: true, id_field: \"#{self_id.name}\" }"
          else
            btn_parts << "{ label: \"#{HecksTemplating::UILabelContract.label(c.name)}\", href: \"/#{p}/#{cm}/new?id=\" + obj.id, allowed: #{mod}.role_allows?(\"#{safe}\", \"#{cm}\") }"
          end
        end
        snake = domain_snake_name(agg.name)
        @domain.aggregates.each do |other|
          next if other.name == agg.name
          other_safe = domain_constant_name(other.name)
          other_p = plural(other)
          other.commands.each do |cmd|
            next unless Hecks::Conventions::CommandContract.find_self_ref(cmd.attributes, agg.name)
            cm = domain_snake_name(cmd.name)
            btn_parts << "{ label: \"#{HecksTemplating::UILabelContract.label(cmd.name)}\", href: \"/#{other_p}/#{cm}/new?id=\" + obj.id, allowed: #{mod}.role_allows?(\"#{other_safe}\", \"#{cm}\") }"
          end
        end
        btn_parts
      end
    end
  end
end
