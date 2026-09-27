require_relative "commands"

module Hecks
  module Release
    class Runner
      # Watches npm for `@hecks/client` after CI publishes it via
      # `.github/workflows/publish-client.yml` (npm trusted publishing).
      #
      # Its clock and pause are injected, so a spec runs the wait without sleeping.
      class CiPublisher
        WORKFLOW = ".github/workflows/publish-client.yml".freeze
        INTERVAL = 15
        LIMIT = 600

        # @param root [String] the repository root
        # @param published [Published] asks npm whether the version is out
        # @param console [Console] progress output
        # @param pause [#call] sleeps for a number of seconds
        # @param now [#call] answers the current time in seconds, monotonically
        def initialize(root:, published:, console:, pause:, now:)
          @root = root
          @published = published
          @console = console
          @pause = pause
          @now = now
        end

        # Says whether the checkout carries the workflow that publishes the client.
        #
        # @return [Boolean] true when `.github/workflows/publish-client.yml` exists
        def workflow?
          File.exist?(File.join(@root, WORKFLOW))
        end

        # Tells the person CI publishes, then waits for the version to reach npm.
        #
        # @param version [String] the version being released
        # @param dry_run [Boolean] say what would happen and wait for nothing
        # @param wait [Boolean] false to report and return without polling
        # @return [Boolean] false only when the wait timed out; true when the version appeared or
        #   nothing was waited for
        def wait!(version, dry_run:, wait:)
          @console.say("CI publishes @hecks/client #{version} from the tag (#{WORKFLOW}); nothing is published from here.")
          return true.tap { preview } if dry_run
          return true.tap { skip_wait(version) } unless wait

          @console.say("Waiting for @hecks/client #{version} on npm (every #{INTERVAL}s, up to #{LIMIT / 60} minutes)...")
          arrived = arrives?(version)
          @console.say("@hecks/client #{version} is on npm.") if arrived
          arrived
        end

        # The hint printed when the wait ends without the version on npm.
        #
        # @param version [String] the version being released
        # @return [String] how to look at, re-run and fall back from the CI publish
        def self.timeout_hint(version)
          "Timed out after #{LIMIT / 60} minutes waiting for CI to publish @hecks/client #{version}. " \
            "See the run: gh run list --workflow publish-client.yml. Re-run it: " \
            "gh workflow run publish-client.yml -f tag=v#{version}. Then finish with: bin/release --npm-only. " \
            "To publish from this machine instead: bin/release --npm-only --npm-local."
        end

        private

        def preview
          @console.say("Dry run: would wait up to #{LIMIT / 60} minutes for it to appear on npm.")
        end

        def skip_wait(version)
          @console.say("Not waiting (--no-wait). Check the run: gh run list --workflow publish-client.yml; " \
                       "npm view @hecks/client@#{version} version")
        end

        def arrives?(version)
          deadline = @now.call + LIMIT
          loop do
            return true if out?(version)
            return false if @now.call >= deadline

            @pause.call(INTERVAL)
          end
        end

        def out?(version)
          @published.npm?(version)
        rescue Refusal
          false
        end
      end
    end
  end
end
