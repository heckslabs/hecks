require_relative "runner/commands"
require_relative "runner/console"
require_relative "runner/git"
require_relative "runner/preflight"
require_relative "runner/published"
require_relative "runner/tagger"
require_relative "runner/gem_publisher"
require_relative "runner/npm_publisher"
require_relative "runner/ci_publisher"
require_relative "runner/options"
require_relative "runner/publishing"

module Hecks
  module Release
    # Performs the release once the release PR has merged: tags the merge
    # commit, publishes the gem, and gets the JS client published to npm.
    #
    # Idempotent: it asks the registries what is already published and skips
    # it, so a run that died between the gem and the package resumes at the package.
    class Runner
      include Publishing

      # The streams and clocks a run talks through, besides the ones a caller names.
      ENVIRONMENT_KEYS = %i[input out err pause now].freeze

      # @param root [String] the repository root
      # @param options [Options] which steps to run and how
      # @param commands [#capture, #run!] starts every process the release runs
      # @param facts [Preflight::Facts, nil] what a caller already checked and cleared (a branch, a
      #   clean tree, matching versions, a changelog entry); the release then checks only that its
      #   tools are installed, and every rule stays with the caller
      # @param environment [Hash] any of: `input` (an IO confirmations are read from, `$stdin`),
      #   `out` (where progress is written, `$stdout`), `err` (where refusals and failures are
      #   written, `$stderr`), `pause` (sleeps for a number of seconds while waiting for CI) and
      #   `now` (the current time in seconds, monotonically, while waiting for CI)
      # @raise [ArgumentError] for any other keyword
      def initialize(root:, options: Options.new, commands: Commands.new, facts: nil, **environment)
        unknown = environment.keys - ENVIRONMENT_KEYS
        raise ArgumentError, "unknown keyword: #{unknown.first.inspect}" unless unknown.empty?

        @root = root
        @facts = facts
        @steps = []
        @verified = false
        @options = options
        @commands = commands
        connect(default_environment.merge(environment))
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
        # Nothing is tagged or pushed until the person has agreed to the publish: the tag push
        # is what starts CI's npm publish.
        return declined unless @options.dry_run || pending.empty? || publish_confirmed?(facts.version, pending)

        tag_then_publish(facts, pending)
      rescue Refusal, CommandFailed => e
        @console.warn(e.message)
        1
      end

      private

      def default_environment
        { input: $stdin, out: $stdout, err: $stderr, pause: ->(seconds) { sleep(seconds) },
          now: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) } }
      end

      def connect(environment)
        @console = Console.new(input: environment[:input], out: environment[:out], err: environment[:err],
                               assume_yes: @options.yes?)
        @git = Git.new(root: @root, commands: @commands)
        @published = Published.new(root: @root, commands: @commands)
        @ci = CiPublisher.new(root: @root, published: @published, console: @console, pause: environment[:pause],
                              now: environment[:now])
      end

      # @return [Integer] the exit status: the publish's, or 1 when the person declined the tag
      #   question
      def tag_then_publish(facts, pending)
        tagger = Tagger.new(git: @git, console: @console, dry_run: @options.dry_run)
        return declined unless tagger.ensure!(facts, note: tag_note(facts.version, pending))

        @steps << :tagged if tagger.changed?
        publish(facts, pending)
      end

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

      # The steps this run's flags put in scope, whether or not a registry already lists them.
      def in_scope
        [(:gem if @options.gem?), (:npm if @options.npm?)].compact
      end

      def ci_publishes?(pending)
        pending.include?(:npm) && !@options.npm_local?
      end

      def require_workflow(pending)
        return unless ci_publishes?(pending) && !@ci.workflow?

        raise Refusal, "#{CiPublisher::WORKFLOW} is not in this checkout, so CI cannot publish @hecks/client; " \
                       "publish it from here with --npm-local (the first publish, before trusted publishing is set up)"
      end

      def declined
        @console.warn("Aborted; nothing was published.")
        1
      end
    end
  end
end
