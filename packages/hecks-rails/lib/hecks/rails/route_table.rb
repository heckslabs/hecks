require "hecks"

module Hecks
  module Rails
    # The routes one chapter's verbs answer on, worked out from its IR and its Site Route rows,
    # with no Rails loaded: `hecks_routes` draws them and the `:rails_app` projection writes them.
    #
    # Every aggregate is a resource with only a `show` route, which a write's redirect resolves
    # against. A command is a POST, a creating one on the collection (there is no record to nest
    # under yet) and the rest on the member; a query is a GET on the collection. A Route row of
    # the Site chapter whose `source` names one of these verbs gives that verb's path and method
    # instead, so a project that declared its routes keeps them.
    #
    # A query's action is its name with `_query` after it (`GET /accounts/open` runs `open_query`),
    # because a query may share its name with a command (Account's `Open`) and one controller
    # cannot hold two actions of one name.
    class RouteTable
      # One resource: the aggregate's routes under its plural name.
      Resource = Struct.new(:name, :controller, :aggregate, :routes, keyword_init: true)

      # One verb's route: `segment` is the URL segment and `action` the controller action. `on` is
      # `:collection` or `:member` for a derived route and nil for one a Route row placed at its own
      # `path`.
      Route = Struct.new(:http_method, :segment, :action, :on, :path, :verb, keyword_init: true)

      # A Route row's `source` naming a command or query: kind, chapter, aggregate, verb.
      SOURCE = /\A(command|query):([A-Za-z0-9_]+)\.([A-Za-z0-9_]+)\.([A-Za-z0-9_]+)\z/

      # @return [Array<RouteTable::Resource>] one resource per aggregate, in declaration order
      attr_reader :resources

      # Names the controller action a verb runs as.
      #
      # @param verb [Bluebook::Command, Bluebook::Query] a command or a query
      # @return [String] the command's snake-case name, or the query's with `_query` after it
      def self.action_for(verb)
        name = Naming.snake(verb.hecks_name)
        verb.is_a?(Bluebook::Query) ? "#{name}_query" : name
      end

      # @param registry [Object] the booted registry, adapter-defined
      # @param chapter [Bluebook::Chapter] the chapter whose verbs are routed
      # @param pluralize [#call] turns a snake-case noun into its plural; Rails passes
      #   ActiveSupport's, so a route agrees with the model's `route_key`
      def initialize(registry, chapter, pluralize: Naming.method(:plural))
        @chapter = chapter
        @rows = declared_rows(registry)
        @resources = chapter.aggregates.map { |aggregate| resource(aggregate, pluralize) }
      end

      private

      def resource(aggregate, pluralize)
        name = pluralize.call(Naming.snake(aggregate.hecks_name))
        routes = aggregate.commands.map { |command| command_route(aggregate, command) } +
                 aggregate.queries.map { |query| query_route(aggregate, query) }
        Resource.new(name: name, controller: name, aggregate: aggregate, routes: routes)
      end

      def command_route(aggregate, command)
        declared(aggregate, command, "command") ||
          Route.new(http_method: :post, segment: Naming.snake(command.hecks_name), action: RouteTable.action_for(command),
                    verb: command, on: command.creates? ? :collection : :member)
      end

      def query_route(aggregate, query)
        declared(aggregate, query, "query") ||
          Route.new(http_method: :get, segment: Naming.snake(query.hecks_name), action: RouteTable.action_for(query),
                    on: :collection, verb: query)
      end

      # The route a Route row gives a verb, or nil when no row names it.
      def declared(aggregate, verb, kind)
        row = @rows["#{kind}:#{@chapter.name}.#{aggregate.hecks_name}.#{verb.hecks_name}"]
        return nil unless row && row[:path]

        method = row[:methods].to_s.split(/[,\s]+/).first || (kind == "command" ? "POST" : "GET")
        Route.new(http_method: method.downcase.to_sym, action: RouteTable.action_for(verb), path: row[:path], verb: verb)
      end

      # Every Route row of the project whose source names a command or query, by that source.
      def declared_rows(registry)
        chapters = registry.bluebooks.values.reject { |chapter| chapter.name == "Site" }
        rows = chapters.flat_map { |chapter| Projections::Site::Table.rows_of(chapter) }
        rows.select { |row| row[:source].to_s.match?(SOURCE) }.to_h { |row| [row[:source].to_s, row] }
      end
    end
  end
end
