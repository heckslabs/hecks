require "open3"

module Hecks
  module Release
    class Runner
      # Raised when a command a release step runs exits non-zero or cannot start.
      class CommandFailed < StandardError; end

      # Raised when a check refuses the release; the message names the fix.
      class Refusal < StandardError; end

      # Runs the release's external commands: git, gem, npm, curl, op.
      #
      # The runner takes any object answering `capture` and `run!` the way this
      # one does, so a spec hands in a recorder and never starts a real process.
      class Commands
        # What a captured command printed and whether it succeeded.
        #
        # @!attribute [r] stdout
        #   @return [String] standard output
        # @!attribute [r] stderr
        #   @return [String] standard error, or the reason the command could not start
        # @!attribute [r] success
        #   @return [Boolean] true when the command exited zero
        Result = Struct.new(:stdout, :stderr, :success, keyword_init: true) do
          # Says whether the command exited zero.
          #
          # @return [Boolean] true when it did
          def success?
            success
          end
        end

        # Runs a command and returns what it printed, whatever its exit status.
        #
        # @param argv [Array<String>] the command and its arguments, never a shell string
        # @param env [Hash{String => String, nil}] variables to set, or unset with nil
        # @param chdir [String, nil] the directory to run in; the current one when nil
        # @return [Result] the output and status; a command that cannot start is a failed result
        def capture(*argv, env: {}, chdir: nil)
          stdout, stderr, status = Open3.capture3(env, *argv, **directory(chdir))
          Result.new(stdout: stdout, stderr: stderr, success: status.success?)
        rescue SystemCallError => e
          Result.new(stdout: "", stderr: e.message, success: false)
        end

        # Runs a command with its output going straight to the terminal.
        #
        # @param argv [Array<String>] the command and its arguments, never a shell string
        # @param env [Hash{String => String, nil}] variables to set, or unset with nil
        # @param chdir [String, nil] the directory to run in; the current one when nil
        # @return [true] when the command exits zero
        # @raise [CommandFailed] if the command exits non-zero or cannot start
        def run!(*argv, env: {}, chdir: nil)
          return true if system(env, *argv, **directory(chdir))

          raise CommandFailed, "`#{argv.first(2).join(' ')}` failed"
        end

        private

        def directory(chdir)
          chdir ? { chdir: chdir } : {}
        end
      end
    end
  end
end
