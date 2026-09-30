require_relative "commands"
require_relative "clean_tree"
require_relative "git"
require_relative "../../cli/release_gem"
require "hecks/hecks/adapters/codebase/gem_registry"

module Hecks
  module Release
    class Runner
      # The gem step: hands the push to `Hecks::CLI::ReleaseGem`, which builds and pushes
      # it with the key 1Password holds; a dry run only builds it, then deletes it.
      class GemPublisher
        # @param root [String] the repository root
        # @param commands [#run!] runs the build and the push
        # @param console [Console] progress output
        def initialize(root:, commands:, console:)
          @root = root
          @commands = commands
          @console = console
          @registry = Hecks::Adapters::Codebase::GemRegistry.new(root: root, commands: commands)
        end

        # Pushes the gem, or with `dry_run` only builds it.
        #
        # @param version [String] the version being released
        # @param dry_run [Boolean] build and delete the gem, pushing nothing
        # @return [void]
        # @raise [CommandFailed] if the build or the push fails
        # @raise [Refusal] if a packaged path holds a modified, untracked or ignored file
        def publish!(version, dry_run:)
          return build_only(version) if dry_run

          CleanTree.new(git: Git.new(root: @root, commands: @commands)).check!

          @console.say("Publishing hecks #{version} to rubygems.org...")
          status = Hecks::CLI::ReleaseGem.call(root: @root, commands: @commands, out: @console.out,
                                               err: @console.err, version: version)
          raise CommandFailed, "the gem push was refused" unless status.zero?
        end

        private

        def build_only(version)
          @console.say("Dry run: building hecks-#{version}.gem (nothing is pushed)...")
          @registry.build_only!(version)
        end
      end
    end
  end
end
