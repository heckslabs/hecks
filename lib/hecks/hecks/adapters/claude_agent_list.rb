# frozen_string_literal: true

require_relative "shell"
require_relative "console_capture"
require_relative "dispatching/checkout"

module Hecks
  module Adapters
    # The agent types the `claude` command can start in a directory: the built-in ones, the user's,
    # the directory's own and the main checkout's.
    #
    # `claude` has no listing of its own, but it names every available agent when asked for one it
    # does not have, and then stops before it starts anything. The list is read from that answer,
    # in the directory a session would work in, so the directory's own agents are counted. A
    # linked worktree or nested checkout holds no `.claude/agents` of its own, so the same question
    # is asked in the repository's main checkout and the two lists are joined. An answer that names
    # no list is refused with what `claude` said, so a reworded message is seen at once, not taken
    # for an empty list; one that says the workspace is not trusted is refused by that name.
    class ClaudeAgentList
      # An agent name no one gives an agent, asked for only to make `claude` name the real ones.
      PROBE = "hecks-probe-not-an-agent"

      # How `claude` names the agents it has, after refusing one it has not.
      AVAILABLE = /Available agents:\s*(.+)$/

      # What `claude` says of a directory its user has not accepted.
      UNTRUSTED = /workspace not trusted/i

      # @param command [String] the program that starts sessions
      # @param shell [Shell] runs it
      def initialize(command, shell: Shell.new)
        @command = command
        @shell = shell
      end

      # @param directory [String] where a session would work
      # @return [Array<String>] the agent names `claude` lists there and in the repository's main
      #   checkout
      # @raise [ConsoleCapture::Failure] when its answer names no list, or says the workspace is
      #   not trusted
      def names(directory)
        [directory, Dispatching::Checkout.main(directory)].uniq.flat_map { |where| listed_in(where) }.uniq
      end

      private

      def listed_in(directory)
        said = probe(directory)
        refuse_untrusted(directory) if said.match?(UNTRUSTED)

        listed = said[AVAILABLE, 1]
        raise ConsoleCapture::Failure, "#{@command} listed no agents: #{said.strip[0, 300]}" unless listed

        listed.split(",").map(&:strip).reject(&:empty?)
      end

      def refuse_untrusted(directory)
        raise ConsoleCapture::Failure, "#{directory} is not a trusted workspace: open claude there once to trust it"
      end

      def probe(directory)
        result = @shell.capture(@command, "--agent", PROBE, "-p", "list the agents", chdir: directory)
        "#{result.out}\n#{result.err}"
      end
    end
  end
end
