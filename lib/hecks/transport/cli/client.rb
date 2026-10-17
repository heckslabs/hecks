# frozen_string_literal: true

require "tmpdir"

module Hecks
  module Transport
    module Cli
      # Runs programs under one set of rules: how long a run may take, and whether runs that are
      # not reads are allowed at all. An adapter holds one and adds only what its service needs.
      class Client
        # @param timeout [Numeric, nil] seconds before a run's process group is stopped; nil lets
        #   a run take as long as it takes
        # @param read_only [Boolean] true refuses every run whose effect is not `:reads`
        def initialize(timeout: nil, read_only: false)
          @timeout = timeout
          @read_only = read_only
        end

        # Runs a program and hands what it said to the block, removing its output files after.
        #
        # @param command [Array<String>] the program, then its arguments; never given to a shell
        # @param effect [Symbol] one of `EFFECTS`: what the run may do to the world
        # @param env [Hash{String => String, nil}] variables to set for it; nil unsets one
        # @param chdir [String, nil] the directory to run it in, or nil for the current one
        # @yieldparam reply [Cli::Reply] what the program said and how it ended
        # @yieldreturn [Object] what the run answers
        # @return [Object] what the block returned
        # @raise [ArgumentError] if `effect` is not one of `EFFECTS`
        # @raise [Cli::ReadOnly] if the client is read-only and `effect` is not `:reads`
        # @raise [Cli::Unavailable] if the program is not installed or runs past the timeout
        def run(*command, effect:, env: {}, chdir: nil)
          permit!(effect, command.first)
          Dir.mktmpdir("hecks-cli") do |dir|
            files = { out: File.join(dir, "out"), err: File.join(dir, "err") }
            yield reply(command, files, env: env, chdir: chdir)
          end
        end

        private

        def permit!(effect, program)
          raise ArgumentError, "#{effect.inspect} is not an effect; one of #{EFFECTS.join(", ")}" unless EFFECTS.include?(effect)
          return unless @read_only && effect != :reads

          raise ReadOnly, "#{program} was not run: this client is read-only and the run #{effect.to_s.tr("_", " ")}"
        end

        def reply(command, files, env:, chdir:)
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          status = Child.run(command, files: files, env: env, chdir: chdir, timeout: @timeout)
          Reply.new(out_path: files[:out], err: File.read(files[:err]), status: status,
                    seconds: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
        end
      end
    end
  end
end
