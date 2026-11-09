# frozen_string_literal: true

require "json"
require_relative "architect_verdict"
require_relative "session_hooks"

module Hecks
  module Adapters
    # The command line that starts one background session: the `claude` command, the agent it runs
    # as, and the brief after a `--` so it is never taken for a flag. An argument list, never a
    # string for a shell. It passes no MCP flags: a resumed session does not keep them, and
    # `--strict-mcp-config` would drop the session's other servers. A role's `hecks-mcp` server
    # narrows itself from the `CLAUDE_CODE_AGENT` variable Claude Code gives it (see
    # `Driving::Mcp::Roles`); a resume names the same role with `--agent` (see
    # {ClaudeResumption}), since without it that variable reads `claude`.
    class SessionLine
      # @param command [String] the command that starts sessions
      # @param nice [Array<String>] the niceness prefix, empty for none
      # @param hooks [SessionHooks] says the hooks a run's session carries
      def initialize(command:, nice:, hooks: SessionHooks.new(launcher: nil))
        @command = command
        @nice = nice
        @hooks = hooks
      end

      # @param held [Hash] the `AgentRun` record: `repo`, `brief`, and `agent` when named
      # @param environment [Hash{String => String}] what the session's own commands should see
      # @return [Array<String>] the argument list
      def arguments(held, environment = {})
        agent = plain(held[:agent])
        [*@nice, @command, *(agent ? ["--agent", agent] : []), *settings(environment, plain(held[:run])), "--bg", "--",
         briefed(plain(held[:brief]), agent)]
      end

      private

      # A background session does not take the environment of the process that starts it, so the
      # variables its commands read (today the caller name) go in the settings `env` block, which
      # Claude Code applies to every command the session runs. The `hooks` block makes the session
      # announce its own end (see {SessionHooks}).
      # @return [Array<String>] the `--settings` flag and its JSON, or nothing for no env or hooks
      def settings(environment, run)
        block = { "env" => environment, "hooks" => @hooks.for(run) }.reject { |_, value| value.empty? }
        block.empty? ? [] : ["--settings", JSON.generate(block)]
      end

      # @return [String] the brief, with the verdict format added for the architect
      def briefed(brief, agent) = agent == "architect" ? "#{brief}#{ArchitectVerdict::REQUEST}" : brief.to_s

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
