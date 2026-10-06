require "json"
require_relative "../page"

module Hecks
  module Forms
    class App
      # The Rack response triples `Forms::App` answers with: HTML pages, JSON bodies, redirects,
      # and the refusal shapes both formats share.
      module Responses
        private

        def html(title, body, breadcrumbs: [], status: 200)
          respond(status, "text/html; charset=utf-8", Page.render(title: title, body: body, breadcrumbs: breadcrumbs))
        end

        def json(status, payload)
          respond(status, "application/json", JSON.pretty_generate(payload))
        end

        def redirect(location)
          [302, { "location" => location }, []]
        end

        def respond(status, content_type, body)
          [status, { "content-type" => content_type }, [body]]
        end

        # A missing record is a 404; every other refusal of the domain or its arguments is a 422.
        def refusal_status(error) = error.is_a?(Runtime::NotFound) ? 404 : 422

        def refusal_json(error, status)
          json(status, { error: error.class.name.split("::").last, message: error.message })
        end

        def not_found(aggregate, id, format)
          return json(404, { error: "NotFound", message: "no #{aggregate.hecks_name} #{id}" }) if format != "html"

          respond(404, "text/html; charset=utf-8",
                  Page.render(title: "not found",
                              body:  "<h1>Not found</h1><p>No #{Escape.html(aggregate.hecks_name)} " \
                                     "#{Escape.html(id)}.</p>"))
        end
      end
    end
  end
end
