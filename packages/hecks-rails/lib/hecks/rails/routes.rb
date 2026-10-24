require_relative "route_table"

module Hecks
  module Rails
    # `hecks_routes "banking"` in `config/routes.rb`: draws a chapter's `RouteTable` with the
    # routing DSL, mixed into `ActionDispatch::Routing::Mapper` by the Railtie.
    #
    # Only GET and POST are drawn. Nothing in a bluebook is a generic replace or delete, so PUT,
    # PATCH and DELETE have no verb to name.
    module Routes
      # Draws every route of one chapter's aggregates.
      #
      # @param chapter [String, Symbol] the chapter's name in any case, `"banking"`
      # @return [void]
      # @raise [Rails::NotBooted] if no domain is booted
      # @raise [ArgumentError] if the domain holds no such chapter
      def hecks_routes(chapter)
        domain = Hecks::Rails.domain
        table = RouteTable.new(domain.registry, domain.chapter(chapter), pluralize: :pluralize.to_proc)
        table.resources.each { |resource| draw_hecks_resource(resource) }
      end

      private

      def draw_hecks_resource(resource)
        placed, nested = resource.routes.partition(&:path)
        resources(resource.name.to_sym, only: [:show]) do
          nested.each { |route| public_send(route.on) { draw_hecks_nested(route) } }
        end
        placed.each { |route| draw_hecks_placed(resource, route) }
      end

      def draw_hecks_nested(route) = public_send(route.http_method, route.segment, action: route.action)

      # A route a Site Route row placed at its own path, named for its action and resource.
      def draw_hecks_placed(resource, route)
        public_send(route.http_method, route.path, to: "#{resource.controller}##{route.action}",
                                                   as: "#{route.action}_#{resource.name}")
      end
    end
  end
end
