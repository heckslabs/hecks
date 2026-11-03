# frozen_string_literal: true

require "securerandom"
require "time"
require_relative "git"
require_relative "console_capture"
require_relative "red_flag_survey"
require_relative "red_flag_kick/reverter"
require_relative "red_flag_kick/effects"
require_relative "red_flag_kick/work_row"

module Hecks
  module Adapters
    # Kicks the red push batch off main for a standing flag, with no hand in it. Every first-parent
    # commit since the last green head of main is reverted, newest first, on `red-main-<cause>`,
    # a red row's fix. The branch is finished onto local main, the train boards the landed tip,
    # a Work row `red-<cause>` is filed naming the failing jobs and the CI run, one coder is
    # dispatched on its brief to bring the batch back green, and the kick's worktree is retired
    # if it is still there. The revert is a new commit; nothing is force-pushed.
    #
    # It refuses, naming why, when no flag stands, a fix has already landed, the batch was already
    # kicked, a session is already fixing the flag, the flag has stood less than the world's
    # `kick_after_minutes` (unless forced), the last green head cannot be told, the batch holds a
    # release commit, or a revert or landing refuses. A refused kick leaves main as it was.
    class RedFlagKick
      class << self
        # @return [Hash{Symbol => #call}, nil] the steps a spec replaces (see {Effects})
        attr_accessor :effects
      end

      # The lead of the revert branch's name.
      BRANCH = "red-main-"

      # The lead of the Work row filed for the batch.
      ROW = "red-"

      # The trailer that marks a release commit, which the owner alone may land.
      RELEASE_TRAILER = /^Release-Approved-By:/

      # How long a flag stands before a kick, when the world says nothing.
      DEFAULT_MINUTES = 60

      # @param marker [RedFlagMarker] the repository's flag
      # @param checkout [String] a directory in the repository
      # @param registry [Runtime::Registry, nil] the booted registry the steps dispatch through
      # @param tune [Hash] `clock:`, `runner:` (reads GitHub) and `kick_after:` (minutes)
      #   replace the defaults, for a spec
      def initialize(marker, checkout, registry: nil, **tune)
        @marker = marker
        @checkout = checkout
        @registry = registry
        @tune = tune
        @git = Git.new
      end

      # @param force [Boolean] kick before the time is up
      # @return [Hash{Symbol => Object}] `flag:` after the kick, `reverted:` the commits newest
      #   first, `branch:` and `row:`
      # @raise [ConsoleCapture::Failure] on any refusal the class describes
      def run(force: false)
        flag = standing(force)
        batch = commits_since(last_green(flag))
        refuse_release!(batch)
        branch = "#{BRANCH}#{flag["id"]}"
        tree = reverter.revert(branch, batch)
        land(branch, tree)
        publish(flag, batch, branch)
        retire(branch, tree)
        kicked(flag, batch, branch)
      end

      private

      def kicked(flag, batch, branch)
        row = WorkRow.new(flag, batch, branch).key
        { flag: @marker.kicked!(branch: branch, reverted: batch, row: row), reverted: batch, branch: branch, row: row }
      end

      def standing(force)
        flag = @marker.read or refuse("no red flag stands: nothing to kick")
        refuse("a fix is already landed at #{flag["fix_tip"][0, 10]} (#{flag["fix_branch"]}); board it") if flag["fix_tip"]
        refuse("the batch was already kicked to #{flag.dig("kicked", "branch")}") if flag["kicked"]
        refuse_fixing!(flag)
        ripe!(flag) unless force
        flag
      end

      def refuse_fixing!(flag)
        taking = Array(flag["checkins"]).map { |held| held["taking"].to_s }.find { |word| word.start_with?(ROW) }
        refuse("#{taking} is already being fixed; the batch is not reverted") if taking
      end

      def ripe!(flag)
        stood = elapsed_minutes(flag)
        return if stood >= kick_after

        refuse("#{flag["id"]} has stood #{stood} min, less than kick_after_minutes (#{kick_after}); " \
               "force.value=true kicks now")
      end

      def elapsed_minutes(flag)
        raised = Time.iso8601(flag.fetch("raised_at"))
        ((@tune.fetch(:clock, -> { Time.now }).call - raised) / 60).to_i
      rescue ArgumentError, KeyError
        0
      end

      def kick_after
        settings = @registry&.world("Hecks")&.for_verb("red_flag")
        @tune[:kick_after] || settings&.dig(:kick_after_minutes) || DEFAULT_MINUTES
      end

      # The newest commit of main whose CI run passed: as the flag recorded it, else as GitHub says.
      def last_green(flag)
        recorded = flag["last_green"].to_s
        green = recorded.empty? ? RedFlagSurvey.new(runner: @tune[:runner], checkout: @checkout).last_green : recorded
        refuse("the last green head of main cannot be told; name it by hand") if green.to_s.empty?
        refuse("the last green head #{green[0, 10]} is not on main") unless git("merge-base", "--is-ancestor", green, "main").ok?
        green
      end

      def commits_since(green)
        listed = out("rev-list", "--first-parent", "#{green}..main").split
        refuse("main holds nothing past the last green head #{green[0, 10]}; nothing to revert") if listed.empty?
        listed
      end

      # A release is the owner's: a commit with a Release-Approved-By trailer is never reverted.
      def refuse_release!(batch)
        held = batch.find { |sha| out("log", "-1", "--format=%B", sha).match?(RELEASE_TRAILER) }
        refuse("#{held[0, 10]} is a release commit; releases are the owner's, so the batch is not reverted") if held
      end

      def reverter = Reverter.new(@git, @checkout)

      def steps = @steps ||= Effects.new(@registry, @tune[:effects] || self.class.effects || {})

      # A refused landing takes the kick's branch and worktree away, so main and the repository
      # are as they were.
      def land(branch, tree)
        steps.run(:land, run: SecureRandom.uuid, checkout: tree, branch: branch, confirm: true)
      rescue ConsoleCapture::Failure
        reverter.tidy(branch, tree)
        raise
      end

      def publish(flag, batch, branch)
        work = WorkRow.new(flag, batch, branch)
        steps.run(:board, run: SecureRandom.uuid, checkout: @checkout, confirm: true)
        steps.run(:plan, work: work.key, title: work.title, detail: work.detail)
        dispatch(work)
      end

      # One coder, briefed on the row, with no agent named: the pipeline picks the agent.
      def dispatch(work)
        brief = steps.run(:brief, work: work.key, outcome: work.title, detail: work.detail)
        steps.run(:dispatch, run: SecureRandom.uuid, repo: @checkout, brief: brief)
      end

      # A landing that finished has removed the worktree; one that left it is retired here.
      def retire(branch, tree)
        return unless File.directory?(tree)

        steps.run(:retire, run: SecureRandom.uuid, checkout: tree, branch: branch, confirm: true)
      end

      def refuse(why) = raise(ConsoleCapture::Failure, why)

      def git(*, dir: @checkout) = @git.capture(*, chdir: dir)

      def out(*) = git(*).out
    end
  end
end
