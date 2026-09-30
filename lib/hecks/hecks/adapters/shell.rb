# frozen_string_literal: true

require "open3"

module Hecks
  module Adapters
    # The `Shell` port's adapter: runs one program with its arguments and hands back what it said.
    #
    # It is the single place a Custodian adapter starts a subprocess through, so `Git` builds on it
    # rather than calling `Open3` itself. The command is an argument list, never a string for a
    # shell to split, so nothing a caller passes is interpreted.
    class Shell
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
      def initialize(aggregate: nil, settings: {}, root: nil); end

      # Runs a program and waits for it.
      #
      # @param command [Array<String>] the program, then its arguments
      # @param env [Hash{String => String, nil}] variables to set for it; nil unsets one
      # @param chdir [String, nil] the directory to run it in
      # @return [Result] its output and status; a program that is not installed is a `Result` with
      #   status 127 and its reason in `err`, not a raise
      def capture(*command, env: {}, chdir: nil)
        options = chdir ? { chdir: chdir } : {}
        out, err, status = Open3.capture3(env, *command, **options)
        Result.new(out, err, status)
      rescue Errno::ENOENT => e
        Result.new("", e.message, Struct.new(:success?, :exitstatus).new(false, 127))
      end
    end
  end
end
