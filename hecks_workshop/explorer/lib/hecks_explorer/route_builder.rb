require "time"

module Hecks
  module HTTP
    # Hecks::HTTP::RouteBuilder
    #
    # Generates REST route definitions from a domain's aggregates. For each
    # aggregate, produces standard CRUD routes (GET index, GET show, POST create,
    # PATCH update, DELETE) and custom query routes. Each route is a Hash with
    # +:method+, +:path+, and +:handler+ (a lambda that processes a request).
    #
    # Used by {Hecks::HTTP::DomainServer} to build its routing table. The
    # generated handlers call the domain's aggregate class methods directly
    # (e.g. +Pizza.all+, +Pizza.create+, +Pizza.find+).
    #
    class RouteBuilder
      include HecksTemplating::NamingHelpers
      # Initialize the builder with a domain definition and its module constant.
      #
      # @param domain [Hecks::Domain] the parsed domain definition containing
      #   aggregate definitions with commands and queries
      # @param mod [Module] the domain module constant (e.g. +PizzasDomain+)
      #   that holds the generated aggregate classes
      # @return [RouteBuilder] a new builder ready to generate routes
      def initialize(domain, mod)
        @domain = domain
        @mod = mod
      end

      # Build and return an array of route hashes for all aggregates.
      #
      # Iterates every aggregate in the domain, resolves its Ruby class
      # constant, computes a URL slug (underscore + pluralized), and
      # generates both query routes and CRUD routes.
      #
      # @return [Array<Hash>] route definitions, each with keys:
      #   - +:method+ [String] HTTP method ("GET", "POST", "PATCH", "DELETE")
      #   - +:path+ [String] URL path pattern (e.g. "/pizzas", "/pizzas/:id")
      #   - +:handler+ [Proc] lambda accepting a RequestWrapper and returning
      #     a serializable result
      def build
        routes = []
        @domain.aggregates.each do |agg|
          klass = @mod.const_get(domain_constant_name(agg.name))
          slug = domain_aggregate_slug(agg.name)
          routes.concat(query_routes(agg, klass, slug))
          routes.concat(crud_routes(agg, klass, slug))
        end
        routes
      end

      private

      # Generate CRUD routes for an aggregate: index, show, create, update, delete.
      #
      # Always generates GET (index), GET (show by :id), and DELETE routes.
      # Conditionally generates POST (create) and PATCH (update) routes only
      # if the aggregate has matching Create*/Update* commands defined.
      #
      # @param agg [Hecks::BluebookModel::Structure::Aggregate] the aggregate definition
      # @param klass [Class] the Ruby class for the aggregate (e.g. +PizzasDomain::Pizza+)
      # @param slug [String] the URL slug (e.g. "pizzas")
      # @return [Array<Hash>] the generated CRUD route hashes
      def crud_routes(agg, klass, slug)
        routes = []
        routes << { method: "GET", path: "/#{slug}", handler: ->(_) { klass.all.map { |r| serialize(r) } } }
        routes << { method: "GET", path: "/#{slug}/:id", handler: ->(req) {
          result = klass.find(req.path.split("/").last)
          result ? serialize(result) : (raise "Not found")
        }}

        create_cmd = agg.commands.find { |c| c.name.start_with?("Create") }
        if create_cmd
          create_method = derive_method(create_cmd.name, agg.name)
          routes << { method: "POST", path: "/#{slug}", handler: ->(req) {
            serialize(klass.send(create_method, **parse_body(req)))
          }}
        end

        update_cmd = agg.commands.find { |c| c.name.start_with?("Update") }
        if update_cmd
          routes << { method: "PATCH", path: "/#{slug}/:id", handler: ->(req) {
            existing = klass.find(req.path.split("/").last)
            raise "Not found" unless existing
            serialize(existing.update(**parse_body(req)))
          }}
        end

        routes << { method: "DELETE", path: "/#{slug}/:id", handler: ->(req) {
          id = req.path.split("/").last; klass.delete(id); { deleted: id }
        }}
        routes
      end

      # Generate query routes for an aggregate's custom queries.
      #
      # Each query becomes a GET endpoint at +/slug/query_name+. The handler
      # passes query string parameters to the query method.
      #
      # @param agg [Hecks::BluebookModel::Structure::Aggregate] the aggregate definition
      # @param klass [Class] the Ruby class for the aggregate
      # @param slug [String] the URL slug
      # @return [Array<Hash>] the generated query route hashes
      def query_routes(agg, klass, slug)
        agg.queries.map do |query|
          qn = domain_snake_name(query.name)
          params = query.block.parameters
          { method: "GET", path: "/#{slug}/#{qn}", handler: ->(req) {
            results = params.empty? ? klass.send(qn.to_sym) : klass.send(qn.to_sym, *params.map { |_type, param_name| req.params[param_name.to_s] })
            results.respond_to?(:map) ? results.map { |result| serialize(result) } : results
          }}
        end
      end

      # Serialize a domain object into a plain Hash of attribute name/value pairs.
      #
      # Uses {Hecks::Utils.object_attr_names} to discover attribute names,
      # then reads each value and serializes it with {#serialize_value}.
      #
      # @param obj [Object] the domain aggregate or value object to serialize
      # @return [Hash{String => Object}] string-keyed hash of serialized attributes
      def serialize(obj)
        Hecks::Utils.object_attr_names(obj).each_with_object({}) do |name, h|
          next unless obj.respond_to?(name)
          h[name.to_s] = serialize_value(obj.send(name))
        end
      end

      # Serialize a single attribute value for JSON output.
      #
      # Handles collections (converts to array of serialized items), Time
      # objects (ISO 8601 format), and passes through primitives unchanged.
      #
      # @param val [Object] the value to serialize
      # @return [Object] the JSON-compatible serialized value
      def serialize_value(val)
        if val.respond_to?(:to_a) && val.respond_to?(:each) && !val.is_a?(Array) && !val.is_a?(Hash) && !val.is_a?(String)
          val.to_a.map { |item| item.respond_to?(:id) ? serialize(item) : serialize_value(item) }
        elsif val.is_a?(Time)
          val.iso8601
        else
          val
        end
      end

      # Parse the JSON body of a request into a symbol-keyed Hash.
      #
      # @param req [RequestWrapper] the request wrapper with a readable body
      # @return [Hash{Symbol => Object}] the parsed body, or empty Hash if body is empty
      def parse_body(req)
        body = req.body.read
        body.empty? ? {} : JSON.parse(body).transform_keys(&:to_sym)
      end

      # Derive the aggregate method name from a command name.
      #
      # Converts "CreatePizza" to :create by underscoring and removing the
      # aggregate name suffix.
      #
      # @param cmd_name [String] the command class name (e.g. "CreatePizza")
      # @param agg_name [Symbol, String] the aggregate name (e.g. :Pizza)
      # @return [Symbol] the method name to call on the aggregate class
      def derive_method(cmd_name, agg_name)
        domain_command_method(cmd_name, agg_name)
      end
    end
  end
end
