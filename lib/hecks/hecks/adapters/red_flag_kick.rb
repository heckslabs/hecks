# frozen_string_literal: true

require "securerandom"
require_relative "git"
require_relative "console_capture"
require_relative "red_flag_survey"
require_relative "red_flag_kick/restorer"
require_relative "red_flag_kick/board_guard"
require_relative "red_flag_kick/effects"
require_relative "red_flag_kick/work_item"

module Hecks
  module Adapters
    # Rolls the red push batch back off main for a standing flag, at once and with no hand in it.
    # Main's tree is restored to the last green head's as one new commit on `red-main-<cause>`
    # (never a force-push, never a rewrite of history). The branch is finished onto local main, the
    # train boards the landed tip, a Work item `red-<cause>` is filed naming the failing jobs and
    # the CI run, one coder is dispatched on its brief to bring the batch back green, and the kick's
    # worktree is retired if it is still there. A restored tree equals a tree CI already passed, so
    # the flag is cleared at once, without waiting for CI on the restore.
    #
    # It refuses, naming why, when no flag stands, a fix has already landed, the batch was already
    # kicked, a session is already fixing the flag, the last green head cannot be told, the batch
    # holds a release commit, the restore or its landing refuses, or local main holds a commit
    # beyond the restore that the push would carry out. A refused kick leaves main as it was.
    class RedFlagKick
      class << self
        # @return [Hash{Symbol => #call}, nil] the steps a spec replaces (see {Effects})
        attr_accessor :effects
      end

      # The lead of the restore branch's name.
      BRANCH = "red-main-"

      # The lead of the Work item filed for the batch.
      WORK_PREFIX = "red-"

      # The trailer that marks a release commit, which the owner alone may land.
      RELEASE_TRAILER = /^Release-Approved-By:/

      # @param marker [RedFlagMarker] the repository's flag
      # @param checkout [String] a directory in the repository
      # @param registry [Runtime::Registry, nil] the booted registry the steps dispatch through
      # @param tune [Hash] `runner:` (reads GitHub) replaces the default, for a spec; `run:` is the
      #   flag request whose record the kick's events act on
      def initialize(marker, checkout, registry: nil, **tune)
        @marker = marker
        @checkout = checkout
        @registry = registry
        @tune = tune
        @git = Git.new
      end

      # @return [Hash{Symbol => Object}] `flag:` after the kick, `restored:` whether the flag was
      #   cleared by the tree match, `reverted:` the commits undone newest first, `branch:` and
      #   `work_item:`
      # @raise [ConsoleCapture::Failure] on any refusal the class describes
      def run
        flag = standing
        green = last_green(flag)
        batch = commits_since(green)
        refuse_release!(batch)
        branch = "#{BRANCH}#{flag["id"]}"
        land(branch, restorer.restore(branch, green, batch))
        guard.check!(green)
        publish(flag, batch, branch)
        retire(branch)
        kicked(flag, batch, branch, guard.same_tree?(green))
      end

      private

      def kicked(flag, batch, branch, restored)
        item = WorkItem.new(flag, batch, branch).key
        held = @marker.kicked!(branch: branch, reverted: batch, work_item: item)
        record(flag, batch.join(", "), item, restored)
        { flag: held, restored: restored, reverted: batch, branch: branch, work_item: item }
      end

      # The flag's events: the kick, then, when the restored tree is a tree CI already passed, the
      # flag coming down.
      def record(flag, reverted, item, restored)
        steps.run(:eject, run: @tune[:run], flag: flag["id"], commit: flag["commit"].to_s, detail: reverted, work_items: item)
        return unless restored

        @marker.clear!
        steps.run(:lift, run: @tune[:run], flag: flag["id"], commit: flag["commit"].to_s)
      end

      def standing
        flag = @marker.read or refuse("no red flag stands: nothing to kick")
        refuse("a fix is already landed at #{flag["fix_tip"][0, 10]} (#{flag["fix_branch"]}); board it") if flag["fix_tip"]
        refuse("the batch was already kicked to #{flag.dig("kicked", "branch")}") if flag["kicked"]
        refuse_fixing!(flag)
        flag
      end

      def refuse_fixing!(flag)
        taking = Array(flag["checkins"]).map { |held| held["taking"].to_s }.find { |word| word.start_with?(WORK_PREFIX) }
        refuse("#{taking} is already being fixed; the batch is not rolled back") if taking
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
        refuse("main holds nothing past the last green head #{green[0, 10]}; nothing to roll back") if listed.empty?
        listed
      end

      # A release is the owner's: a commit with a Release-Approved-By trailer is never rolled back.
      def refuse_release!(batch)
        held = batch.find { |sha| out("log", "-1", "--format=%B", sha).match?(RELEASE_TRAILER) }
        refuse("#{held[0, 10]} is a release commit; releases are the owner's, so the batch is not rolled back") if held
      end

      def restorer = Restorer.new(@git, @checkout)

      def guard = BoardGuard.new(@git, @checkout)

      def steps = @steps ||= Effects.new(@registry, @tune[:effects] || self.class.effects || {})

      # A refused landing takes the kick's branch and worktree away, so main and the repository
      # are as they were.
      def land(branch, tree)
        @tree = tree
        steps.run(:land, run: SecureRandom.uuid, checkout: tree, branch: branch, confirm: true)
      rescue ConsoleCapture::Failure
        restorer.tidy(branch, tree)
        raise
      end

      def publish(flag, batch, branch)
        work = WorkItem.new(flag, batch, branch)
        steps.run(:board, run: SecureRandom.uuid, checkout: @checkout, confirm: true)
        steps.run(:plan, work: work.key, title: work.title, detail: work.detail)
        dispatch(work)
      end

      # One coder, briefed on the work item, with no agent named: the pipeline picks the agent.
      def dispatch(work)
        brief = steps.run(:brief, work: work.key, outcome: work.title, detail: work.detail)
        steps.run(:dispatch, run: SecureRandom.uuid, repo: @checkout, brief: brief)
      end

      # A landing that finished has removed the worktree; one that left it is retired here.
      def retire(branch)
        return unless File.directory?(@tree)

        steps.run(:retire, run: SecureRandom.uuid, checkout: @tree, branch: branch, confirm: true)
      end

      def refuse(why) = raise(ConsoleCapture::Failure, why)

      def git(*, dir: @checkout) = @git.capture(*, chdir: dir)

      def out(*) = git(*).out.strip
    end
  end
end
