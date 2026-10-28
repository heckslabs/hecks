module Hecks
  module Rails
    # The HTTP routes a bluebook's aggregate commands imply, as data: a `show` for each aggregate
    # and one POST per command.
    #
    # Nothing in the language maps to REST's generic update or destroy, because every command is a
    # specific named verb, so a write is always a POST and a read is always a GET. A creating
    # command has no record to nest under, so it routes to the collection; any other command
    # already knows its subject, so it routes to the member.
    module CommandRoutes
      # One route: `scope` is `:collection` or `:member`, `action` is the controller action.
      Route = Struct.new(:http_method, :resource, :scope, :action, keyword_init: true) do
        def show? = action == "show"
      end

      module_function

      # @param bluebook [Hecks::Bluebook::Declaration] a booted bluebook
      # @return [Array<Route>] every route its aggregates imply, aggregate by aggregate
      def for_chapter(chapter) = chapter.aggregates.flat_map { |aggregate| for_aggregate(aggregate) }

      # @param aggregate [Hecks::Bluebook::Aggregate] one aggregate
      # @return [Array<Route>] its `show`, then a POST per command
      def for_aggregate(aggregate)
        resource = Naming.snake(aggregate.hecks_name).to_s
        [Route.new(http_method: :get, resource: resource, scope: :member, action: "show"),
         *aggregate.commands.map { |command| command_route(resource, command) }]
      end

      # @return [Route] the POST for one command
      def command_route(resource, command)
        Route.new(http_method: :post, resource: resource, action: Naming.snake(command.hecks_name).to_s,
                  scope: command.creates? ? :collection : :member)
      end
    end
  end
end
