# frozen_string_literal: true

require "securerandom"
require "time"
require "hecks/runtime/dispatcher"
require_relative "git"
require_relative "console_capture"
require_relative "red_flag_survey"
require_relative "red_flag_kick/reverter"

module Hecks
  module Adapters
    # Kicks the red push batch off main for a fixer: every first-parent commit since the last
    # green head of main is reverted, newest first, on a branch named for the flag
    # (`red-kick-<flag>`, a red row's fix, so Landing takes it while the flag stands), the branch
    # lands on local main, and a Work row (`reland-<flag>`) is filed with the commits for their
    # owner to land again once fixed. The push train boards the landed tip as the flag's fix, and
    # the green run that follows lowers the flag. Nothing is force-pushed: the revert is a new
    # commit.
    #
    # It refuses, naming why, when no flag stands, a fix has already landed, the batch was already
    # kicked, the flag has stood less than the world's `kick_after_minutes` (unless forced), the
    # last green head cannot be told, or a revert conflicts; a refused kick leaves main as it was.
    class RedFlagKick
      # The lead of the revert branch's name.
      BRANCH = "red-kick-"

      # The lead of the Work row filed for the owner of the kicked batch.
      ROW = "reland-"

      # How long a flag stands before a kick, when the world says nothing.
      DEFAULT_MINUTES = 60

      # @param marker [RedFlagMarker] the repository's flag
      # @param checkout [String] a directory in the repository
      # @param registry [Runtime::Registry, nil] the booted registry the landing and the row go
      #   through
      # @param tune [Hash] `clock:`, `runner:` (reads GitHub), `kick_after:` (minutes), `lander:`
      #   (takes the branch and its worktree) and `filer:` (takes the flag, the batch and the
      #   branch, answers the row) replace the defaults, for a spec
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
        branch = "#{BRANCH}#{flag["id"]}"
        tree = reverter.revert(branch, batch)
        lander.call(branch, tree)
        row = filer.call(flag, batch, branch)
        reverter.tidy(branch, tree)
        { flag: @marker.kicked!(branch: branch, reverted: batch, row: row), reverted: batch, branch: branch, row: row }
      end

      private

      def standing(force)
        flag = @marker.read or refuse("no red flag stands: nothing to kick")
        refuse("a fix is already landed at #{flag["fix_tip"][0, 10]} (#{flag["fix_branch"]}); board it") if flag["fix_tip"]
        refuse("the batch was already kicked to #{flag.dig("kicked", "branch")}") if flag["kicked"]
        ripe!(flag) unless force
        flag
      end

      def ripe!(flag)
        stood = elapsed_minutes(flag)
        return if stood >= kick_after

        refuse("#{flag["id"]} has stood #{stood} min, less than kick_after_minutes (#{kick_after}); force.value=true kicks now")
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

      def reverter = Reverter.new(@git, @checkout)

      def lander
        @tune[:lander] || lambda do |branch, tree|
          top_level("Hecks::Landing.Land", run: SecureRandom.uuid, checkout: tree, branch: branch, confirm: true)
        end
      end

      def filer
        @tune[:filer] || lambda do |flag, batch, branch|
          row = "#{ROW}#{flag["id"]}"
          top_level("Tickets::Work.Plan", work: row, title: title(flag), detail: detail(flag, batch, branch))
          row
        end
      end

      # The landing and the row are dispatches of their own, as an operator would make them, not
      # reactions of the kick: each starts its own reaction chain, so the depth the kick's ask
      # reached does not count against the landing's.
      def top_level(verb, **args)
        depth = Thread.current[:hecks_reaction_depth]
        Thread.current[:hecks_reaction_depth] = 0
        Runtime::Dispatcher.new(@registry).dispatch_flat(verb, args)
      ensure
        Thread.current[:hecks_reaction_depth] = depth
      end

      def title(flag) = "Land again the push batch kicked off main for #{flag["id"]}, once its CI failure is fixed"

      def detail(flag, batch, branch)
        "Main was red at #{flag["commit"]} (#{flag["id"]}); #{branch} reverted these commits, newest first: " \
          "#{batch.join(", ")}. Fix the failure on a branch that reapplies them and land it; the revert stays on main."
      end

      def refuse(why) = raise(ConsoleCapture::Failure, why)

      def git(*, dir: @checkout) = @git.capture(*, chdir: dir)

      def out(*) = git(*).out
    end
  end
end
