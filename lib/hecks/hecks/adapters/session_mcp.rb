# frozen_string_literal: true

require "json"

module Hecks
  module Adapters
    # The MCP servers a dispatched role session starts, narrowed to the role. The checkout's
    # `.mcp.json` names the servers every session starts, and it carries no environment per role;
    # `claude --mcp-config` takes a JSON string, so a role whose routing rows name commands starts
    # with a copy of that file whose `hecks-mcp` entry carries the role's `HECKS_SERVER_*`
    # variables, and `--strict-mcp-config` keeps the checkout's unrestricted entry from starting
    # beside it.
    #
    # It decides nothing: which variables a role gets is the `ServerEnv` query's, and a role with
    # none starts as before.
    class SessionMcp
      # The `.mcp.json` entry that takes the role's variables.
      SERVER = "hecks-mcp"

      # @param server_env [#call, nil] answers a role name with its `HECKS_SERVER_*` variables, or
      #   empty; the Agents bluebook's `ServerEnv` query when none is given
      def initialize(server_env: nil)
        @server_env = server_env || method(:role_variables)
      end

      # @param repo [String] the directory the session works in, whose `.mcp.json` is read
      # @param agent [String, nil] the role the session runs as
      # @return [Array<String>] the `claude` flags, empty when the role has no variables or the
      #   checkout has no `hecks-mcp` entry to narrow
      def arguments(repo:, agent:)
        variables = agent ? @server_env.call(agent) : {}
        config = variables.empty? ? nil : narrowed(read(repo), variables)
        config ? ["--mcp-config", JSON.generate(config), "--strict-mcp-config"] : []
      end

      private

      def role_variables(role)
        require "hecks/agents/adapters/routing_guard"
        (@guard ||= RoutingGuard.new).server_variables(role)
      end

      def narrowed(config, variables)
        entry = config&.dig("mcpServers", SERVER)
        return unless entry

        entry["env"] = (entry["env"] || {}).merge(variables)
        config
      end

      def read(repo)
        JSON.parse(File.read(File.join(repo.to_s, ".mcp.json")))
      rescue SystemCallError, JSON::ParserError
        nil
      end
    end
  end
end
