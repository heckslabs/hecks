module Hecks
  module Rails
    # Makes `resources :accounts` draw an aggregate's command routes when `accounts` is one:
    # an `index` and a `show`, then a POST per command. A creating command routes to the collection
    # and any other to the member, because it already knows its subject. Nothing in the language
    # maps to REST's update or destroy, so a write is always a POST. Any other resource draws as
    # usual.
    module Routes
      RESOURCES = ActionDispatch::Routing::Mapper::Resources.instance_method(:resources)

      # @param names [Array<Symbol>] the resources to draw
      # @return [void]
      def resources(*names, **options, &block)
        aggregates = names.map { |name| domain_aggregate(name) }
        return super unless aggregates.all?

        names.zip(aggregates) { |name, aggregate| domain_resource(name, aggregate, options, block) }
      end

      private

      def domain_aggregate(name)
        return unless Booted.booted?

        singular = name.to_s.singularize
        Booted.app_bluebooks.flat_map(&:aggregates).find { |a| Naming.snake(a.hecks_name).to_s == singular }
      end

      def domain_resource(name, aggregate, options, block)
        routes = CommandRoutes.for_aggregate(aggregate).reject(&:show?)
        RESOURCES.bind_call(self, name, only: [:index, :show], **options) do
          instance_exec(&block) if block
          routes.each { |route| public_send(route.scope) { post route.action } }
        end
      end
    end
  end
end

ActionDispatch::Routing::Mapper.prepend(Hecks::Rails::Routes)
