module Hecks
  module MCP
    class DomainServer
      # Hecks::MCP::DomainServer::QueryTools
      #
      # Mixin that registers MCP tools for domain queries. Each query on each
      # aggregate becomes a callable MCP tool. Handles both parameterized queries
      # (with input arguments) and zero-argument queries.
      #
      # Query results that respond to +map+ (collections) are serialized element
      # by element, joined with newlines. Scalar results are converted with +to_s+.
      #
      # Mixed into DomainServer -- expects the following instance state:
      #   - +@server+ [MCP::Server] -- the MCP server to register tools on
      #   - +@domain+ [Hecks::DomainModel::Structure::Domain] -- the domain model
      #   - +@mod+ [Module] -- the generated domain module (e.g. PizzasDomain)
      #
      # Also expects this helper method from DomainServer:
      #   - +serialize_aggregate(obj)+ -- formats a domain object as a readable string
      #
      module QueryTools
        include HecksTemplating::NamingHelpers
        private

        # Iterates all aggregates in the domain and registers each of their
        # queries as an MCP tool.
        #
        # @return [void]
        def register_query_tools
          @domain.aggregates.each do |agg|
            agg_class = @mod.const_get(domain_constant_name(agg.name))
            agg.queries.each do |query|
              register_query(agg, agg_class, query)
            end
          end
        end

        # Registers a single query as an MCP tool. Inspects the query block's
        # parameters to determine if it is zero-arg or parameterized, and
        # builds the appropriate JSON Schema input.
        #
        # For zero-arg queries, the tool name is +"AggName_method_name"+ with
        # no required inputs. For parameterized queries, each block parameter
        # becomes a required string input.
        #
        # @param agg [Hecks::DomainModel::Structure::Aggregate] the aggregate owning the query
        # @param agg_class [Class] the generated Ruby class for the aggregate
        # @param query [Object] the query object with +name+, +block+ (a Proc with parameters)
        # @return [void]
        def register_query(agg, agg_class, query)
          method_name = domain_snake_name(query.name).to_sym
          params = query.block.parameters
          klass = agg_class
          attr_list = agg.attributes.map { |a| "#{a.name}: #{a.ruby_type}" }.join(", ")

          if params.empty?
            desc = build_query_description(agg, method_name, [], attr_list)
            @server.define_tool(
              name: "#{agg.name}_#{method_name}",
              description: desc,
              input_schema: { type: "object", properties: {} }
            ) do |_|
              results = klass.send(method_name)
              results.respond_to?(:map) ? results.map { |r| serialize_aggregate(r) }.join("\n") : results.to_s
            end
          else
            param_names = params.map { |_, name| name.to_s }
            props = params.each_with_object({}) do |(_, name), h|
              h[name.to_s] = { type: "string", description: "#{name} (string, required). Example: \"example_#{name}\"" }
            end
            desc = build_query_description(agg, method_name, param_names, attr_list)
            @server.define_tool(
              name: "#{agg.name}_#{method_name}",
              description: desc,
              input_schema: { type: "object", properties: props, required: props.keys }
            ) do |args|
              values = params.map { |_, name| args[name.to_s] }
              results = klass.send(method_name, *values)
              results.respond_to?(:map) ? results.map { |r| serialize_aggregate(r) }.join("\n") : results.to_s
            end
          end
        end

        # Builds a rich description for a query tool including what it does,
        # accepted parameters, and the shape of the result set.
        #
        # @param agg [Hecks::DomainModel::Structure::Aggregate] the aggregate
        # @param method_name [Symbol] the query method name
        # @param param_names [Array<String>] parameter names (empty for zero-arg queries)
        # @param attr_list [String] comma-separated attribute descriptions for the return shape
        # @return [String] the full description
        def build_query_description(agg, method_name, param_names, attr_list)
          parts = []
          parts << "Queries the #{agg.name} aggregate using the #{method_name} finder."
          if param_names.any?
            parts << "Accepts parameters: #{param_names.join(', ')} (all required, string type)."
          else
            parts << "Takes no parameters."
          end
          parts << "Returns: newline-separated list of #{agg.name} objects, each with fields (#{attr_list}, id, created_at, updated_at)."
          parts.join(" ")
        end
      end
    end
  end
end
