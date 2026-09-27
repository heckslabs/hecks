require "hecks/vendoring/git_environment"
require_relative "commands"

module Hecks
  module Release
    class Runner
      # The release's view of the repository: git run in the checkout, with the
      # repository-pinning environment variables a git hook exports unset.
      class Git
        # @param root [String] the repository root
        # @param commands [#capture, #run!] runs the git commands
        def initialize(root:, commands:)
          @root = root
          @commands = commands
        end

        # Runs a git command and returns what it printed.
        #
        # @param args [Array<String>] git's arguments
        # @return [String] standard output
        # @raise [Refusal] if git exits non-zero
        def read(*args)
          result = capture(*args)
          raise Refusal, "git #{args.first} failed: #{result.stderr.strip}" unless result.success?

          result.stdout
        end

        # Runs a git command and returns the result whatever its status.
        #
        # @param args [Array<String>] git's arguments
        # @return [Commands::Result] output and status
        def capture(*)
          @commands.capture("git", *, env: Vendoring::GitEnvironment.clean, chdir: @root)
        end

        # Runs a git command that changes something, showing its output.
        #
        # @param args [Array<String>] git's arguments
        # @return [true] when git exits zero
        # @raise [CommandFailed] if git exits non-zero
        def run!(*)
          @commands.run!("git", *, env: Vendoring::GitEnvironment.clean, chdir: @root)
        end
      end
    end
  end
end
