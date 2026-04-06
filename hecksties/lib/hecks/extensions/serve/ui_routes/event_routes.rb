
module Hecks
  module HTTP
    class MultiDomainServer
      module UIRoutes
        # Hecks::HTTP::MultiDomainServer::UIRoutes::EventRoutes
        #
        # Handles event listing and JSON endpoints for the multi-domain
        # web explorer. Supports filtering by event type and aggregate,
        # with pagination.
        #
        #   # Mixed into UIRoutes, called from MultiDomainServer#handle
        #   serve_events(req, res)
        #   serve_events_json(res)
        #
        module EventRoutes
          private

          def serve_events_json(res)
            evts = @entries.flat_map { |e| e[:runtime].event_bus.events }
            res["Content-Type"] = "application/json"
            res.body = JSON.generate(evts.map { |e|
              { type: Hecks::Utils.const_short_name(e),
                occurred_at: (e.occurred_at.iso8601 rescue nil) }
            })
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
            e.merge(
              occurred_at_display: ts,
              payload_display: e[:payload].map { |k, v| "#{k}: #{v}" }.join("\n")
            )
          end
        end
      end
    end
  end
end
