
module Hecks
  module HTTP
    class MultiDomainServer
      module UIRoutes
        # Hecks::HTTP::MultiDomainServer::UIRoutes::FormRoute
        #
        # Serves the command form page (new) and handles form submission.
        # On success, redirects to the show page. On failure, re-renders
        # the form with the error message.
        #
        #   # Mixed into UIRoutes, called from route dispatcher
        #   serve_form(req, res, ir, agg, safe, p, prefix, cmd_snake)
        #   serve_submit(req, res, ir, bridge, agg, safe, p, prefix, cmd_snake)
        #
        module FormRoute
          include HecksTemplating::NamingHelpers

          private

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
        end
      end
    end
  end
end
