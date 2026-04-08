
module Hecks
  module HTTP
    class MultiDomainServer
      module UIRoutes
        # Hecks::HTTP::MultiDomainServer::UIRoutes::RouteDispatcher
        #
        # Dispatches incoming UI requests to the correct route handler
        # (index, show, form, submit) based on the URL path. Also provides
        # search parameter parsing and CSRF validation.
        #
        #   # Mixed into UIRoutes, called from MultiDomainServer
        #   serve_ui_route(req, res, entry, sub_path)
        #
        module RouteDispatcher
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

            safe = bluebook_constant_name(agg.name)
            p = plural(agg)
            prefix = "/#{slug}"
            remaining = sub_path.sub("/#{p}", "")

            dispatch_remaining(req, res, ir, bridge, agg, safe, p, prefix, remaining)
          end

          def dispatch_remaining(req, res, ir, bridge, agg, safe, p, prefix, remaining)
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
end
