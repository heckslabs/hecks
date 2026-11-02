# frozen_string_literal: true

require_relative "shell"
require_relative "console_capture"

module Hecks
  module Adapters
    # The agent types the `claude` command can start in a directory: the built-in ones, the user's
    # and the directory's own.
    #
    # `claude` has no listing of its own, but it names every available agent when asked for one it
    # does not have, and then stops before it starts anything. The list is read from that answer,
    # in the directory a session would work in, so the directory's own agents are counted. An
    # answer that names no list is refused with what `claude` said, so a reworded message is seen at
    # once, not taken for an empty list.
    class ClaudeAgentList
      # An agent name no one gives an agent, asked for only to make `claude` name the real ones.
      PROBE = "hecks-probe-not-an-agent"

      # How `claude` names the agents it has, after refusing one it has not.
      AVAILABLE = /Available agents:\s*(.+)$/

      # @param command [String] the program that starts sessions
      # @param shell [Shell] runs it
      def initialize(command, shell: Shell.new)
        @command = command
        @shell = shell
      end

      # @param directory [String] where a session would work
      # @return [Array<String>] the agent names `claude` lists there
      # @raise [ConsoleCapture::Failure] when its answer names no list
      def names(directory)
        result = @shell.capture(@command, "--agent", PROBE, "-p", "list the agents", chdir: directory)
        said = "#{result.out}\n#{result.err}"
        listed = said[AVAILABLE, 1]
        raise ConsoleCapture::Failure, "#{@command} listed no agents: #{said.strip[0, 300]}" unless listed

        listed.split(",").map(&:strip).reject(&:empty?)
      end
    end
  end
end
