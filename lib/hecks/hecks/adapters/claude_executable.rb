# frozen_string_literal: true

require_relative "console_capture"

module Hecks
  module Adapters
    # Finds the `claude` program a session is started or listed with, by its place on `PATH` first
    # and then by a declared list of places it is installed.
    #
    # A pipeline step runs with the `PATH` of whoever started it, which need not hold `claude`
    # (the daemon finds it at `~/.local/bin/claude`). The places to look are the Tickets world's
    # `claude_executable` line, else `CANDIDATES`. A program found nowhere is a named refusal.
    class ClaudeExecutable
      # The program asked for by name.
      COMMAND = "claude"

      # Where `claude` is installed when the world names no places, in the order they are tried.
      CANDIDATES = %w[~/.local/bin/claude ~/.claude/local/claude /opt/homebrew/bin/claude /usr/local/bin/claude
                      /Applications/Claude.app/Contents/MacOS/claude].freeze

      # @param candidates [Array<String>] the places to look when `PATH` has no `claude`
      # @param path [String, nil] the `PATH` to search; the process's when nil
      def initialize(candidates: CANDIDATES, path: nil)
        @candidates = Array(candidates).map { |place| File.expand_path(place.to_s) }
        @path = path || ENV.fetch("PATH", "")
      end

      # @return [String] `claude` when `PATH` holds it, else the first candidate that is a program
      # @raise [ConsoleCapture::Failure] when neither does
      def resolve
        return COMMAND if on_path?

        @candidates.find { |place| program?(place) } || raise(ConsoleCapture::Failure, refusal)
      end

      # @return [Boolean] whether {#resolve} finds a program
      def found?
        resolve
        true
      rescue ConsoleCapture::Failure
        false
      end

      private

      def refusal = "#{COMMAND} is not on the path and none of #{@candidates.join(", ")} exists"

      def on_path? = @path.split(File::PATH_SEPARATOR).any? { |dir| program?(File.join(dir, COMMAND)) }

      def program?(place) = File.file?(place) && File.executable?(place)
    end
  end
end
