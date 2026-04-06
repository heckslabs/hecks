
module Hecks
  module HTTP
    class MultiDomainServer
      module UIRoutes
        # Hecks::HTTP::MultiDomainServer::UIRoutes::IndexRoute
        #
        # Serves the aggregate index page with search, filtering, computed
        # attributes, and create-command buttons. Uses IRIntrospector for
        # structural discovery and RuntimeBridge for data access.
        #
        #   # Mixed into UIRoutes, called from route dispatcher
        #   serve_index(req, res, ir, bridge, agg, safe, p, prefix)
        #
        module IndexRoute
          include HecksTemplating::NamingHelpers

          private

          def serve_index(req, res, ir, bridge, agg, safe, p, prefix)
            token = ensure_csrf_cookie(req, res)
            q, filters = parse_search_params(req)
            user_attrs = ir.user_attributes(agg)
            filterable = ir.filterable_attributes(agg).map(&:name)
            records = bridge.search_and_filter(agg.name, string_attr_names: filterable, query: q, filters: filters)
            items = build_index_items(ir, bridge, user_attrs, records, prefix, p)
            append_computed_cells(ir, bridge, agg, items)
            columns = ir.columns_for(agg)
            buttons = build_create_buttons(ir, agg, prefix, p)
            html = @renderer.render(:index,
              title: "#{safe}s — #{@brand}", brand: @brand, nav_items: @nav,
              aggregate_name: safe, items: items, columns: columns,
              buttons: buttons, row_actions: [], csrf_token: token,
              search_query: q.to_s, index_url: "#{prefix}/#{p}")
            res["Content-Type"] = "text/html"
            res.body = html
          end

          def build_index_items(ir, bridge, user_attrs, records, prefix, p)
            records.map do |obj|
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
          end

          def append_computed_cells(ir, bridge, agg, items)
            ir.computed_attributes(agg).each do |ca|
              items.each do |item|
                obj = bridge.find_by_id(agg.name, item[:id])
                item[:cells] << bridge.evaluate_computed(obj, ca.block) if obj
              end
            end
          end

          def build_create_buttons(ir, agg, prefix, p)
            ir.create_commands(agg).map do |c|
              cm = domain_snake_name(c.name)
              { label: HecksTemplating::UILabelContract.label(c.name),
                href: "#{prefix}/#{p}/#{cm}/new", allowed: true }
            end
          end
        end
      end
    end
  end
end
