require "fileutils"
require_relative "commands"

module Hecks
  module Release
    class Runner
      # The gem step: hands the push to `bin/release_gem`, which owns building the
      # gem and pushing it with the key 1Password holds. A dry run builds the gem
      # to prove it builds and deletes it.
      class GemPublisher
        # @param root [String] the repository root
        # @param commands [#run!] runs the build and the push
        # @param console [Console] progress output
        def initialize(root:, commands:, console:)
          @root = root
          @commands = commands
          @console = console
        end

        # Pushes the gem, or with `dry_run` only builds it.
        #
        # @param version [String] the version being released
        # @param dry_run [Boolean] build and delete the gem, pushing nothing
        # @return [void]
        # @raise [CommandFailed] if the build or the push fails
        def publish!(version, dry_run:)
          return build_only(version) if dry_run

          @console.say("Publishing hecks #{version} to rubygems.org via bin/release_gem...")
          @commands.run!(File.join(@root, "bin/release_gem"), chdir: @root)
        end

        private

        def build_only(version)
          @console.say("Dry run: building hecks-#{version}.gem (nothing is pushed)...")
          @commands.run!("gem", "build", "hecks.gemspec", chdir: @root)
        ensure
          FileUtils.rm_f(File.join(@root, "hecks-#{version}.gem"))
        end
      end
    end
  end
end
