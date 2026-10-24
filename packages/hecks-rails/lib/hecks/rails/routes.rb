module Hecks
  module Rails
    # The `hecks_routes` word for a Rails routes file:
    #
    #     Rails.application.routes.draw { hecks_routes "ledger" }
    #
    # Each aggregate gets `only: [:show]`, which every write's redirect resolves through, and a
    # POST per command from `CommandRoutes`.
    module Routes
      # @param chapter_name [String, Symbol] a booted chapter's name, in any case
      # @return [void]
      def hecks_routes(chapter_name)
        routes = CommandRoutes.for_chapter(Booted.chapter(chapter_name))
        routes.group_by(&:resource).each do |resource, resource_routes|
          resources(resource.pluralize.to_sym, only: [:show]) do
            resource_routes.reject(&:show?).each { |route| hecks_command_route(route) }
          end
        end
      end

      # @param route [CommandRoutes::Route] one command's POST
      # @return [void]
      def hecks_command_route(route)
        public_send(route.scope) { post route.action }
      end
    end
  end
end

ActionDispatch::Routing::Mapper.include(Hecks::Rails::Routes)
