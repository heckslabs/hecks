# frozen_string_literal: true

require_relative "architect_verdict"

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
      def initialize(command:, nice:)
        @command = command
        @nice = nice
      end

      # @param held [Hash] the `AgentRun` record: `repo`, `brief`, and `agent` when named
      # @return [Array<String>] the argument list
      def arguments(held)
        agent = plain(held[:agent])
        [*@nice, @command, *(agent ? ["--agent", agent] : []), "--bg", "--", briefed(plain(held[:brief]), agent)]
      end

      private

      # @return [String] the brief, with the verdict format added for the architect
      def briefed(brief, agent) = agent == "architect" ? "#{brief}#{ArchitectVerdict::REQUEST}" : brief.to_s

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
