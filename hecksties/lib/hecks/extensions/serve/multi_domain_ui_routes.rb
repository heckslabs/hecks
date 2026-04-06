
require_relative "ui_routes/event_routes"
require_relative "ui_routes/route_dispatcher"
require_relative "ui_routes/index_route"
require_relative "ui_routes/show_route"
require_relative "ui_routes/form_route"

module Hecks
  module HTTP
    class MultiDomainServer
      # Hecks::HTTP::MultiDomainServer::UIRoutes
      #
      # UI route handlers for the multi-domain web explorer. Structural
      # discovery (columns, fields, buttons) comes from IRIntrospector.
      # Runtime data access (find, all, execute) goes through RuntimeBridge.
      #
      # Each concern is extracted into its own submodule:
      #   EventRoutes     — event listing and JSON endpoints
      #   RouteDispatcher — URL dispatch, search parsing, CSRF validation
      #   IndexRoute      — aggregate index with search and filtering
      #   ShowRoute       — aggregate detail page
      #   FormRoute       — command form rendering and submission
      #
      module UIRoutes
        include HecksTemplating::NamingHelpers
        include CsrfHelpers
        include UIRoutes::EventRoutes
        include UIRoutes::RouteDispatcher
        include UIRoutes::IndexRoute
        include UIRoutes::ShowRoute
        include UIRoutes::FormRoute
      end
    end
  end
end
