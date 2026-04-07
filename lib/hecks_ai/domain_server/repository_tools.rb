module Hecks
  module MCP
    class DomainServer
      # Hecks::MCP::DomainServer::RepositoryTools
      #
      # Mixin that registers MCP tools for aggregate CRUD/read operations. Each
      # aggregate in the domain gets three tools:
      #   - +Find<Name>+   -- look up a single aggregate instance by ID
      #   - +All<Name>s+   -- list all instances of the aggregate
      #   - +Count<Name>s+ -- return the total count of aggregate instances
      #
      # These tools delegate to the repository methods bound on the aggregate class
      # (+find+, +all+, +count+) which are wired to in-memory adapters by DomainServer.
      #
      # Mixed into DomainServer -- expects the following instance state:
      #   - +@server+ [MCP::Server] -- the MCP server to register tools on
      #   - +@domain+ [Hecks::DomainModel::Structure::Domain] -- the domain model
      #   - +@mod+ [Module] -- the generated domain module (e.g. PizzasDomain)
      #
      # Also expects this helper method from DomainServer:
      #   - +serialize_aggregate(obj)+ -- formats a domain object as a readable string
      #
      module RepositoryTools
        include HecksTemplating::NamingHelpers
        private

        # Registers Find, All, and Count tools for each aggregate in the domain.
        #
        # @return [void]
        def register_repository_tools
          @domain.aggregates.each do |agg|
            agg_class = @mod.const_get(domain_constant_name(agg.name))
            name = agg.name
            klass = agg_class
            attr_list = agg.attributes.map { |a| "#{a.name}: #{a.ruby_type}" }.join(", ")

            @server.define_tool(
              name: "Find#{name}",
              description: "Looks up a single #{name} by its unique ID (UUID string). " \
                           "Parameter: id (string, required). Example: \"abc-123\". " \
                           "Returns: #{name} object with fields (#{attr_list}, id, created_at, updated_at), " \
                           "or \"Not found\" if no #{name} exists with that ID.",
              input_schema: {
                type: "object",
                properties: { id: { type: "string", description: "UUID of the #{name} to find. Example: \"abc-123\"" } },
                required: ["id"]
              }
            ) do |args|
              result = klass.find(args["id"])
              result ? serialize_aggregate(result) : "Not found"
            end

            @server.define_tool(
              name: "All#{name}s",
              description: "Lists every #{name} instance in the repository. Takes no parameters. " \
                           "Returns: newline-separated list of all #{name} objects, each with fields " \
                           "(#{attr_list}, id, created_at, updated_at). Returns empty string if none exist.",
              input_schema: { type: "object", properties: {} }
            ) do |_|
              klass.all.map { |r| serialize_aggregate(r) }.join("\n")
            end

            @server.define_tool(
              name: "Count#{name}s",
              description: "Returns the total number of #{name} instances in the repository. " \
                           "Takes no parameters. Returns: a single integer as a string (e.g. \"5\").",
              input_schema: { type: "object", properties: {} }
            ) do |_|
              klass.count.to_s
            end
          end
        end
      end
    end
  end
end
