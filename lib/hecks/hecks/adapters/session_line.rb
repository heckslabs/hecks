# frozen_string_literal: true

require_relative "architect_verdict"

module Hecks
  module Adapters
    # The command line that starts one background session: the `claude` command, the agent it runs
    # as, the MCP servers narrowed to the role, and the brief after a `--` so it is never taken for
    # a flag. An argument list, never a string for a shell.
    class SessionLine
      # What to tell whoever reads the start report, once {#arguments} has been asked.
      #
      # @return [Array<String>] notes on the MCP servers the session was started with
      attr_reader :notes

      # @param command [String] the command that starts sessions
      # @param nice [Array<String>] the niceness prefix, empty for none
      # @param mcp [#call] the role's MCP flags and notes (`SessionMcp`)
      def initialize(command:, nice:, mcp:)
        @command = command
        @nice = nice
        @mcp = mcp
        @notes = []
      end

      # @param held [Hash] the `AgentRun` record: `repo`, `brief`, `run`, and `agent` when named
      # @return [Array<String>] the argument list
      def arguments(held)
        agent = plain(held[:agent])
        servers = @mcp.call(repo: plain(held[:repo]), agent: agent, run: plain(held[:run]))
        @notes = servers.notes
        [*@nice, @command, *(agent ? ["--agent", agent] : []), *servers.flags, "--bg", "--", briefed(plain(held[:brief]), agent)]
      end

      # @return [Hash{Symbol => Hash}] the start report's `note:` for the MCP servers, or empty when
      #   there is nothing to say
      def report = notes.empty? ? {} : { note: { value: notes.join("; ") } }

      private

      # @return [String] the brief, with the verdict format added for the architect
      def briefed(brief, agent) = agent == "architect" ? "#{brief}#{ArchitectVerdict::REQUEST}" : brief.to_s

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
