
module Hecks
  module HTTP
    class MultiDomainServer
      module UIRoutes
        # Hecks::HTTP::MultiDomainServer::UIRoutes::ShowRoute
        #
        # Serves the aggregate detail/show page. Renders user attributes
        # and computed attributes for a single domain object found by ID.
        #
        #   # Mixed into UIRoutes, called from route dispatcher
        #   serve_show(req, res, ir, bridge, agg, safe, p, prefix)
        #
        module ShowRoute
          private

          def serve_show(req, res, ir, bridge, agg, safe, p, prefix)
            token = ensure_csrf_cookie(req, res)
            obj = bridge.find_by_id(agg.name, req.query["id"])
            unless obj
              res.status = 404; res.body = "Not found"; return
            end
            fields = build_show_fields(ir, bridge, obj, agg)
            html = @renderer.render(:show,
              title: "#{safe} — #{@brand}", brand: @brand, nav_items: @nav,
              aggregate_name: safe, back_href: "#{prefix}/#{p}",
              id: bridge.read_id(obj), fields: fields, buttons: [], csrf_token: token)
            res["Content-Type"] = "text/html"
            res.body = html
          end

          def build_show_fields(ir, bridge, obj, agg)
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
              fields << {
                label: "#{Hecks::Utils.humanize(Hecks::Utils.sanitize_constant(ca.name))} (computed)",
                value: bridge.evaluate_computed(obj, ca.block)
              }
            end
            fields
          end
        end
      end
    end
  end
end
