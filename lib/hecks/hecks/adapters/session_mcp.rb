# frozen_string_literal: true

require "json"
require_relative "session_config_file"

module Hecks
  module Adapters
    # The MCP servers a dispatched role session starts, narrowed to the role. The checkout's
    # `.mcp.json` names the servers every session starts, and it carries no environment per role;
    # `claude --mcp-config` takes a configuration, so a role whose routing rows name commands starts
    # with a copy of that file whose `hecks-mcp` entry carries the role's `HECKS_SERVER_*`
    # variables, and `--strict-mcp-config` keeps the checkout's unrestricted entry from starting
    # beside it. The copy is a file only its owner can read, not an argument `ps` would show.
    #
    # A role with no routing rows starts as before. A role that has rows never gets the
    # unrestricted server: when its variables are empty or the checkout has no `hecks-mcp` entry to
    # narrow (or no `.mcp.json`), the session starts with the configuration without that server,
    # and the start report says why. Which variables a role gets is the `ServerEnv` query's, read
    # from the checkout the session works in.
    class SessionMcp
      # The `.mcp.json` entry that takes the role's variables.
      SERVER = "hecks-mcp"

      # The flags for `claude`, and what to tell whoever reads the start report.
      Result = Struct.new(:flags, :notes)

      NONE = Result.new([].freeze, [].freeze).freeze
      private_constant :NONE

      # @param server_env [#call, nil] answers a role name and the checkout with the role's plan
      #   (`rows:`, `variables:`, `unserved:`), or a bare hash of variables; the Agents bluebook's
      #   rows when none is given
      # @param files [SessionConfigFile, nil] where configurations are written
      def initialize(server_env: nil, files: nil)
        @server_env = server_env || method(:role_plan)
        @files = files || SessionConfigFile.new
      end

      # @param repo [String] the directory the session works in, whose `.mcp.json` is read
      # @param agent [String, nil] the role the session runs as
      # @param run [String, nil] the run, which names the configuration file
      # @return [Result] the `claude` flags, empty for a session with no role or a role with no
      #   routing rows, and the notes for the start report
      def call(repo:, agent:, run: nil)
        plan = agent ? normalized(@server_env.call(agent, repo)) : { rows: false }
        return NONE unless plan[:rows]

        config, notes = narrowed(read(repo), plan)
        Result.new(["--mcp-config", @files.write(config, run), "--strict-mcp-config"], notes + unserved(plan, repo))
      end

      # @return [Array<String>] the flags {#call} answers
      def arguments(repo:, agent:, run: nil) = call(repo: repo, agent: agent, run: run).flags

      # Removes the configuration of a run whose session was removed.
      #
      # @param run [String] the run
      # @return [void]
      def discard(run:) = @files.discard(run)

      private

      def role_plan(role, repo)
        require "hecks/agents/adapters/routing_guard"
        RoutingGuard.new(checkout: repo).server_plan(role)
      rescue StandardError => e
        RoutingGuard.new.server_plan(role).merge(fallback: "#{e.class}: #{e.message}")
      end

      def normalized(answer) = answer.key?(:rows) ? answer : { rows: !answer.empty?, variables: answer }

      def narrowed(config, plan)
        entry = config&.dig("mcpServers", SERVER)
        reason = unnarrowable(config, entry, plan)
        return [without_server(config), ["#{SERVER} is not started: #{reason}"]] if reason

        entry["env"] = (entry["env"] || {}).merge(plan[:variables])
        [config, []]
      end

      def unnarrowable(config, entry, plan)
        return ".mcp.json is missing or unreadable" unless config
        return "no #{SERVER} entry in .mcp.json" unless entry

        "no routing row of the role names a command of the checkout" if plan.fetch(:variables, {}).empty?
      end

      def without_server(config)
        servers = (config || {}).fetch("mcpServers", {}).reject { |name, _| name == SERVER }
        (config || {}).merge("mcpServers" => servers)
      end

      def unserved(plan, repo)
        notes = []
        notes << "MCP rows and commands came from the dispatcher's checkout (#{plan[:fallback]})" if plan[:fallback]
        missing = plan[:unserved].to_a
        notes << "no command of #{repo}/lib/hecks/hecks matches: #{missing.join(", ")}" unless missing.empty?
        notes
      end

      def read(repo)
        parsed = JSON.parse(File.read(File.join(repo.to_s, ".mcp.json")))
        parsed.is_a?(Hash) ? parsed : nil
      rescue SystemCallError, JSON::ParserError
        nil
      end
    end
  end
end
