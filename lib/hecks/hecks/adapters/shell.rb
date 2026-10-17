# frozen_string_literal: true

require "hecks/transport/cli"

module Hecks
  module Adapters
    # The `Shell` port's adapter: runs one program with its arguments and hands back what it said.
    #
    # It is the single place a Custodian adapter starts a subprocess through, so `Git` builds on it
    # rather than spawning a process itself. The command is an argument list, never a string for a
    # shell to split, so nothing a caller passes is interpreted. The run goes through
    # `Transport::Cli`, so an interrupt stops the program and every process it started.
    class Shell
      # How a program that could not be started ended: as a missing command does under `sh`.
      NOT_INSTALLED = Struct.new(:success?, :exitstatus).new(false, 127).freeze

      # What a program said and how it ended.
      #
      # @!attribute [r] out
      #   @return [String] what it wrote to stdout
      # @!attribute [r] err
      #   @return [String] what it wrote to stderr
      # @!attribute [r] status
      #   @return [Process::Status] how it ended
      Result = Struct.new(:out, :err, :status) do
        # @return [Boolean] whether the program ended with status 0
        def ok? = status.success?
      end

      # Accepts the arguments every driven adapter is built with and keeps none of them.
      #
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil)
        @client = Transport::Cli::Client.new
      end

      # Runs a program and waits for it, however long it takes.
      #
      # A shell cannot know what the program does, so the run declares the widest effect.
      #
      # @param command [Array<String>] the program, then its arguments
      # @param env [Hash{String => String, nil}] variables to set for it; nil unsets one
      # @param chdir [String, nil] the directory to run it in
      # @return [Result] its output and status; a program that is not installed is a `Result` with
      #   status 127 and its reason in `err`, not a raise
      def capture(*command, env: {}, chdir: nil)
        @client.run(*command, effect: :executes_foreign_code, env: env, chdir: chdir) do |reply|
          Result.new(reply.out, reply.err, reply.status)
        end
      rescue Transport::Cli::NotInstalled => e
        Result.new("", e.message, NOT_INSTALLED)
      end
    end
  end
end
