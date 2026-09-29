require_relative "runner/commands"
require_relative "runner/console"
require_relative "runner/git"
require_relative "runner/preflight"
require_relative "runner/published"
require_relative "runner/tagger"
require_relative "runner/gem_publisher"
require_relative "runner/npm_publisher"
require_relative "runner/ci_publisher"

module Hecks
  module Release
    # Performs the release once the release PR has merged: tags the merge
    # commit, publishes the gem, and gets the JS client published to npm.
    #
    # Idempotent: it asks the registries what is already published and skips
    # it, so a run that died between the gem and the package resumes at the package.
    class Runner
      # Which steps to run and how.
      class Options
        # @return [Boolean] run every check and build, but tag, push and publish nothing
        attr_reader :dry_run

        # @param dry_run [Boolean] run every check and build, but tag, push and publish nothing
        # @param gem_only [Boolean] publish the gem, not the package
        # @param npm_only [Boolean] do the npm step only, not the gem: wait for CI's publish, or
        #   with `npm_local` publish from here
        # @param npm_local [Boolean] publish the package from this machine, not by CI
        # @param no_wait [Boolean] do not wait for CI's publish to reach npm
        # @param yes [Boolean] answer every confirmation yes
        # @raise [ArgumentError] if the flags contradict each other
        def initialize(dry_run: false, gem_only: false, npm_only: false, npm_local: false, no_wait: false, yes: false)
          check_flags(gem_only, npm_only, npm_local, no_wait)

          @dry_run = dry_run
          @gem_only = gem_only
          @npm_only = npm_only
          @npm_local = npm_local
          @no_wait = no_wait
          @yes = yes
        end

        # Says whether confirmations are answered automatically.
        #
        # @return [Boolean] true under `--yes`
        def yes?
          @yes
        end

        # Says whether the gem step is in scope.
        #
        # @return [Boolean] true unless `--npm-only`
        def gem?
          !@npm_only
        end

        # Says whether the npm step is in scope.
        #
        # @return [Boolean] true unless `--gem-only`
        def npm?
          !@gem_only
        end

        # Says whether the package is published from this machine.
        #
        # @return [Boolean] true under `--npm-local`
        def npm_local?
          @npm_local
        end

        # Says whether to wait for CI's publish to reach npm.
        #
        # @return [Boolean] true unless `--no-wait`
        def wait?
          !@no_wait
        end

        private

        def check_flags(gem_only, npm_only, npm_local, no_wait)
          raise ArgumentError, "--gem-only and --npm-only cannot be combined" if gem_only && npm_only
          raise ArgumentError, "--gem-only and --npm-local cannot be combined" if gem_only && npm_local
          return unless no_wait && npm_local

          raise ArgumentError, "--no-wait applies to CI's publish, so it cannot be combined with --npm-local"
        end
      end

      # @param root [String] the repository root
      # @param options [Options] which steps to run and how
      # @param commands [#capture, #run!] starts every process the release runs
      # @param input [IO] where confirmations are read from
      # @param out [IO] where progress is written
      # @param err [IO] where refusals and failures are written
      # @param pause [#call] sleeps for a number of seconds while waiting for CI
      # @param now [#call] answers the current time in seconds, monotonically, while waiting for CI
      # @param facts [Preflight::Facts, nil] what a caller already checked and cleared (a branch, a
      #   clean tree, matching versions, a changelog entry); the release then checks only that its
      #   tools are installed, and every rule stays with the caller
      def initialize(root:, options: Options.new, commands: Commands.new, input: $stdin, out: $stdout, err: $stderr,
                     pause: ->(seconds) { sleep(seconds) }, now: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                     facts: nil)
        @root = root
        @facts = facts
        @steps = []
        @verified = false
        @options = options
        @commands = commands
        @console = Console.new(input: input, out: out, err: err, assume_yes: options.yes?)
        @git = Git.new(root: root, commands: commands)
        @published = Published.new(root: root, commands: commands)
        @ci = CiPublisher.new(root: root, published: @published, console: @console, pause: pause, now: now)
      end

      # @return [Array<Symbol>] the steps this run carried out for real: `:tagged`, `:gem`, `:npm`
      attr_reader :steps

      # @return [Boolean] whether, after a real run, every registry in scope lists the version
      attr_reader :verified

      # Runs the release.
      #
      # @return [Integer] 0 when the release finished or had nothing to do, 1 when a check refused,
      #   a step failed, CI's publish did not arrive in time or a confirmation was declined
      def call
        facts = preflight
        pending = pending_steps(facts.version)
        require_workflow(pending)
        tagger = Tagger.new(git: @git, console: @console, dry_run: @options.dry_run)
        return declined unless tagger.ensure!(facts)

        @steps << :tagged if tagger.changed?
        publish(facts, pending)
      rescue Refusal, CommandFailed => e
        @console.warn(e.message)
        1
      end

      private

      def preflight
        check = Preflight.new(root: @root, commands: @commands, git: @git, tools: tools)
        return check.check! unless @facts

        check.check_tools!
        @facts
      end

      def tools
        list = %w[git curl]
        list << "gem" if @options.gem?
        list << "npm" if @options.npm?
        list << "op" if !@options.dry_run && (@options.gem? || @options.npm_local?)
        list
      end

      def pending_steps(version)
        [
          (:gem if @options.gem? && !done?("hecks #{version} is already on rubygems.org", @published.gem?(version))),
          (:npm if @options.npm? && !done?("@hecks/client #{version} is already on npm", @published.npm?(version)))
        ].compact
      end

      def done?(message, published)
        @console.say("#{message}; skipping.") if published
        published
      end

      def ci_publishes?(pending)
        pending.include?(:npm) && !@options.npm_local?
      end

      def require_workflow(pending)
        return unless ci_publishes?(pending) && !@ci.workflow?

        raise Refusal, "#{CiPublisher::WORKFLOW} is not in this checkout, so CI cannot publish @hecks/client; " \
                       "publish it from here with --npm-local (the first publish, before trusted publishing is set up)"
      end

      def publish(facts, pending)
        if pending.empty?
          @console.say("Nothing to publish for #{facts.version}.")
          return 0
        end
        return declined unless @options.dry_run || publish_confirmed?(facts.version, pending)

        run_steps(facts.version, pending)
      end

      def publish_confirmed?(version, pending)
        targets = []
        targets << "hecks #{version} to rubygems.org" if pending.include?(:gem)
        targets << "@hecks/client #{version} to npm" if pending.include?(:npm) && @options.npm_local?
        return true if targets.empty?

        suffix = ci_publishes?(pending) ? " (CI then publishes @hecks/client from the tag)" : ""
        @console.confirm?("Publish #{targets.join(' and ')}#{suffix}? This cannot be undone.")
      end

      def run_steps(version, pending)
        dry_run = @options.dry_run
        publish_gem(version, dry_run) if pending.include?(:gem)
        return 1 if pending.include?(:npm) && !publish_npm!(version, dry_run, ci_publishes?(pending))

        @verified = registries_list?(version, pending) unless dry_run

        @console.say(dry_run ? "Dry run complete; nothing was tagged, pushed or published." : "Released hecks #{version}.")
        0
      end

      def publish_gem(version, dry_run)
        GemPublisher.new(root: @root, commands: @commands, console: @console).publish!(version, dry_run: dry_run)
        @steps << :gem unless dry_run
      end

      # Asks each registry a step published to whether it now lists the version.
      def registries_list?(version, pending)
        (!pending.include?(:gem) || @published.gem?(version)) && (!pending.include?(:npm) || @published.npm?(version))
      rescue Refusal
        false
      end

      def publish_npm!(version, dry_run, via_ci)
        return wait_for_ci!(version, dry_run) if via_ci

        NpmPublisher.new(root: @root, commands: @commands, console: @console).publish!(version, dry_run: dry_run)
        @steps << :npm unless dry_run
        true
      rescue CommandFailed => e
        @console.warn("npm publish failed: #{e.message}")
        unless dry_run
          @console.warn("Finish the release with: bin/release --npm-only --npm-local (published steps are not repeated)")
        end
        raise
      end

      def wait_for_ci!(version, dry_run)
        arrived = @ci.wait!(version, dry_run: dry_run, wait: @options.wait?)
        @steps << :npm if arrived && !dry_run
        @console.warn(CiPublisher.timeout_hint(version)) unless arrived
        arrived
      end

      def declined
        @console.warn("Aborted; nothing was published.")
        1
      end
    end
  end
end
