require "mcp"

Hecks::Chapters.load_aggregates(
  Hecks::Chapters::AI::DomainServerParagraph,
  base_dir: File.expand_path("domain_server", __dir__)
)

module Hecks
  module MCP
    # Hecks::MCP::DomainServer
    #
    # Generates an MCP server from a compiled Hecks domain. Every command becomes
    # a callable tool, every query becomes a tool, and every aggregate gets
    # Find/All/Count repository tools. Boots with memory adapters for zero-setup,
    # no-database operation.
    #
    # Tool registration is split into three mixins:
    #   - +CommandTools+    -- one tool per command per aggregate
    #   - +QueryTools+      -- one tool per query per aggregate
    #   - +RepositoryTools+ -- Find/All/Count per aggregate
    #
    # This class handles the full lifecycle: loading the domain into memory via
    # InMemoryLoader (no disk I/O), booting a runtime with memory adapters, and
    # registering all tools on the MCP server.
    #
    #   hecks mcp --domain NAME
    #
    class DomainServer
      include HecksTemplating::NamingHelpers
      include CommandTools
      include QueryTools
      include RepositoryTools

      # Builds an MCP server from the given domain. Compiles the domain gem,
      # loads it, boots a runtime, and registers all command/query/repository tools.
      #
      # @param domain [Hecks::DomainModel::Structure::Domain] the domain model to serve
      def initialize(domain)
        @domain = domain
        @server = ::MCP::Server.new(
          name: "#{domain.name} Domain",
          version: Hecks::VERSION
        )
        boot_and_register
      end

      # Starts the MCP server using stdio transport. Blocks until the transport
      # is closed by the client.
      #
      # @return [void]
      def run
        require "mcp/server/transports/stdio_transport"
        ::MCP::Server::Transports::StdioTransport.new(@server).open
      end

      private

      # Orchestrates the full boot sequence: build gem, load it, boot runtime,
      # and register all tool groups.
      #
      # @return [void]
      def boot_and_register
        build_and_load
        boot_application
        register_command_tools
        register_query_tools
        register_repository_tools
      end

      # Loads the domain into memory using InMemoryLoader (no disk I/O) and
      # sets +@mod+ to the generated domain module constant.
      #
      # If the domain module is already defined in the Ruby runtime (e.g., from
      # a prior load), it reuses it without reloading.
      #
      # @return [void]
      def build_and_load
        mod_name = domain_module_name(@domain.name)
        return @mod = Object.const_get(mod_name) if Object.const_defined?(mod_name)

        Hecks.load_domain(@domain, force: true)
        @mod = Object.const_get(mod_name)
      end

      # Boots a Hecks::Runtime for the domain and binds repository methods
      # (find, all, count, etc.) onto each aggregate class.
      #
      # @return [void]
      def boot_application
        @app = Runtime.new(@domain)
        @domain.aggregates.each do |agg|
          agg_class = @mod.const_get(domain_constant_name(agg.name))
          Persistence::RepositoryMethods.bind(agg_class, @app[agg.name])
        end
      end

      # Derives the Ruby method name for a command by stripping the aggregate
      # name suffix from the command name. For example, +CreatePizza+ on the
      # +Pizza+ aggregate yields +:create+.
      #
      # Falls back to the full underscored command name if no suffix matches.
      #
      # @param cmd_name [String] the PascalCase command name (e.g. "CreatePizza")
      # @param agg_name [String] the PascalCase aggregate name (e.g. "Pizza")
      # @return [Symbol] the derived method name (e.g. +:create+)
      def derive_method_name(cmd_name, agg_name)
        full = domain_snake_name(cmd_name)
        snake_agg = domain_snake_name(agg_name)
        # Try full name first, then each word suffix (ai_model -> model)
        snake_agg.split("_").each_index do |i|
          suffix = snake_agg.split("_").drop(i).join("_")
          stripped = full.sub(/_#{suffix}$/, "")
          return stripped.to_sym if stripped != full
        end
        full.to_sym
      end

      # Converts a domain attribute's Ruby type to a JSON Schema type string.
      #
      # @param attr [Hecks::DomainModel::Structure::Attribute] the attribute to inspect
      # @return [String] the JSON Schema type: "integer", "number", or "string"
      def json_type(attr)
        case attr.ruby_type
        when "Integer" then "integer"
        when "Float" then "number"
        else "string"
        end
      end

      # Serializes a domain aggregate instance into a human-readable string
      # showing its class name and attribute values.
      #
      # @param obj [Object] a domain aggregate instance
      # @return [String] e.g. "Pizza(name: \"Margherita\", size: \"large\")"
      def serialize_aggregate(obj)
        attrs = Hecks::Utils.object_attr_names(obj).map do |name|
          next unless obj.respond_to?(name)
          "#{name}: #{obj.send(name).inspect}"
        end.compact
        "#{obj.class.name.split('::').last}(#{attrs.join(', ')})"
      end
    end
  end
end
