# frozen_string_literal: true

require_relative "architect_verdict"

module Hecks
  module Adapters
    # The command line that starts one background session: the `claude` command, the agent it runs
    # as, the MCP servers narrowed to the role, and the brief after a `--` so it is never taken for
    # a flag. An argument list, never a string for a shell.
    class SessionLine
      # @param command [String] the command that starts sessions
      # @param nice [Array<String>] the niceness prefix, empty for none
      # @param mcp [#arguments] the role's MCP flags (`SessionMcp`)
      def initialize(command:, nice:, mcp:)
        @command = command
        @nice = nice
        @mcp = mcp
      end

      # @param held [Hash] the `AgentRun` record: `repo`, `brief`, and `agent` when one is named
      # @return [Array<String>] the argument list
      def arguments(held)
        agent = plain(held[:agent])
        [*@nice, @command, *(agent ? ["--agent", agent] : []), *@mcp.arguments(repo: plain(held[:repo]), agent: agent),
         "--bg", "--", briefed(plain(held[:brief]), agent)]
      end

      private

      # @return [String] the brief, with the verdict format added for the architect
      def briefed(brief, agent) = agent == "architect" ? "#{brief}#{ArchitectVerdict::REQUEST}" : brief.to_s

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
