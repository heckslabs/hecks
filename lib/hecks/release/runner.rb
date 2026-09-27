require_relative "runner/commands"
require_relative "runner/console"
require_relative "runner/git"
require_relative "runner/preflight"
require_relative "runner/published"
require_relative "runner/tagger"
require_relative "runner/gem_publisher"
require_relative "runner/npm_publisher"

module Hecks
  module Release
    # Performs the release once the release PR has merged: tags the merge
    # commit, publishes the gem to rubygems.org and publishes the JavaScript
    # client to npm.
    #
    # ## Why it exists
    #
    # A release is four steps that have to happen in one order, and only
    # the contributing guide remembered it. This runs them in that order, refuses to
    # start from a checkout that is not the merged `main`, and can be run again:
    # it asks the registries what is already published and skips it, so a run
    # that died between the gem and the package resumes at the package.
    #
    # ## Steps
    #
    # 1. Preflight: tools installed, on a clean `main` equal to `origin/main`,
    #    the gem and the client at one version, the changelog naming it.
    # 2. Published state: which of the gem and the package are already out.
    # 3. Tag: an annotated `vX.Y.Z` on the release commit, pushed to origin.
    # 4. Gem: `bin/release_gem`, unchanged.
    # 5. npm: `npm publish` with a token 1Password holds.
    #
    # ## Injectable commands
    #
    # Every process is started through `commands`, any object answering
    # `capture(*argv, env:, chdir:)` and `run!(*argv, env:, chdir:)` like
    # {Commands}, so a spec drives the whole release with a recorder.
    class Runner
      # Which steps to run and how.
      class Options
        # @return [Boolean] run every check and build, but tag, push and publish nothing
        attr_reader :dry_run

        # @param dry_run [Boolean] run every check and build, but tag, push and publish nothing
        # @param gem_only [Boolean] publish the gem, not the package
        # @param npm_only [Boolean] publish the package, not the gem
        # @param yes [Boolean] answer every confirmation yes
        # @raise [ArgumentError] if both `gem_only` and `npm_only` are set
        def initialize(dry_run: false, gem_only: false, npm_only: false, yes: false)
          raise ArgumentError, "--gem-only and --npm-only cannot be combined" if gem_only && npm_only

          @dry_run = dry_run
          @gem_only = gem_only
          @npm_only = npm_only
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
      end

      # @param root [String] the repository root
      # @param options [Options] which steps to run and how
      # @param commands [#capture, #run!] starts every process the release runs
      # @param input [IO] where confirmations are read from
      # @param out [IO] where progress is written
      # @param err [IO] where refusals and failures are written
      def initialize(root:, options: Options.new, commands: Commands.new, input: $stdin, out: $stdout, err: $stderr)
        @root = root
        @options = options
        @commands = commands
        @console = Console.new(input: input, out: out, err: err, assume_yes: options.yes?)
        @git = Git.new(root: root, commands: commands)
      end

      # Runs the release.
      #
      # @return [Integer] 0 when the release finished or had nothing to do, 1 when a check refused,
      #   a step failed or a confirmation was declined
      def call
        facts = Preflight.new(root: @root, commands: @commands, git: @git, tools: tools).check!
        pending = pending_steps(facts.version)
        return declined unless Tagger.new(git: @git, console: @console, dry_run: @options.dry_run).ensure!(facts)

        publish(facts, pending)
      rescue Refusal, CommandFailed => e
        @console.warn(e.message)
        1
      end

      private

      def tools
        list = %w[git curl]
        list << "gem" if @options.gem?
        list << "npm" if @options.npm?
        list << "op" unless @options.dry_run
        list
      end

      def pending_steps(version)
        published = Published.new(root: @root, commands: @commands)
        [
          (:gem if @options.gem? && !done?("hecks #{version} is already on rubygems.org", published.gem?(version))),
          (:npm if @options.npm? && !done?("@hecks/client #{version} is already on npm", published.npm?(version)))
        ].compact
      end

      def done?(message, published)
        @console.say("#{message}; skipping.") if published
        published
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
        targets = pending.map { |step| step == :gem ? "hecks #{version} to rubygems.org" : "@hecks/client #{version} to npm" }
        @console.confirm?("Publish #{targets.join(' and ')}? This cannot be undone.")
      end

      def run_steps(version, pending)
        dry_run = @options.dry_run
        publish_gem(version, dry_run) if pending.include?(:gem)
        publish_npm(version, dry_run) if pending.include?(:npm)
        @console.say(dry_run ? "Dry run complete; nothing was tagged, pushed or published." : "Released hecks #{version}.")
        0
      end

      def publish_gem(version, dry_run)
        GemPublisher.new(root: @root, commands: @commands, console: @console).publish!(version, dry_run: dry_run)
      end

      def publish_npm(version, dry_run)
        NpmPublisher.new(root: @root, commands: @commands, console: @console).publish!(version, dry_run: dry_run)
      rescue CommandFailed => e
        @console.warn("npm publish failed: #{e.message}")
        @console.warn("Finish the release with: bin/release --npm-only (published steps are not repeated)") unless dry_run
        raise
      end

      def declined
        @console.warn("Aborted; nothing was published.")
        1
      end
    end
  end
end
