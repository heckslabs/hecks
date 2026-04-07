# = Hecks::Chapters::Extensions::ServeRoutesChapter
#
# Self-describing sub-chapter for HTTP route handling internals:
# request wrapping, CORS, CSRF, route dispatch, and individual
# route handlers (index, show, form, events).
#
#   Hecks::Chapters::Extensions::ServeRoutesChapter.define(builder)
#
module Hecks
  module Chapters
    module Extensions
      # Hecks::Chapters::Extensions::ServeRoutesChapter
      #
      # Bluebook sub-chapter for HTTP route handling: request wrapping, CORS, CSRF, and route dispatch.
      #
      module ServeRoutesChapter
        def self.define(b)
          b.aggregate "RequestWrapper", "Wraps WEBrick request for consistent route handler interface" do
            command("Wrap") { attribute :path, String; attribute :method, String }
          end

          b.aggregate "CorsHeaders", "ENV-driven CORS origin header middleware" do
            command("ApplyOrigin") { attribute :origin, String }
          end

          b.aggregate "CsrfHelpers", "Double-submit cookie CSRF protection mixin" do
            command("Validate") { attribute :cookie_token, String; attribute :header_token, String }
            command("EnsureCookie") { attribute :request_id, String }
          end

          b.aggregate "RouteDispatcher", "Dispatches UI requests to index/show/form handlers by URL path" do
            command("Dispatch") { attribute :path, String; attribute :method, String }
          end

          b.aggregate "IndexRoute", "Serves aggregate index pages with search, filtering, and computed attributes" do
            command("ServeIndex") { attribute :aggregate_name, String }
          end

          b.aggregate "ShowRoute", "Serves aggregate detail pages with user and computed attributes" do
            command("ServeShow") { attribute :aggregate_name, String; attribute :id, String }
          end

          b.aggregate "FormRoute", "Renders command forms and handles form submission with CSRF" do
            command("ServeForm") { attribute :command_name, String }
            command("ServeSubmit") { attribute :command_name, String; attribute :params, String }
          end

          b.aggregate "EventRoutes", "Handles event listing and JSON endpoints with filtering and pagination" do
            command("ServeEvents") { attribute :type_filter, String }
            command("ServeEventsJson") { attribute :format, String }
          end

          b.aggregate "UIRoutes", "Multi-domain UI route composition module" do
            command("Mount") { attribute :domain_slug, String }
          end

          b.aggregate "HttpConnection", "Connection wrapper for declarative boot block HTTP listeners" do
            command("Connect") { attribute :host, String; attribute :port, Integer }
            command("Start") { attribute :reason, String }
          end
        end
      end
    end
  end
end
