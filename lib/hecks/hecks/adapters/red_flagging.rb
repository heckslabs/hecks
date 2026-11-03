# frozen_string_literal: true

require_relative "git"
require_relative "console_capture"
require_relative "red_flag_marker"
require_relative "red_flag_report"
require_relative "red_flag_survey"
require_relative "red_flag_kick"

module Hecks
  module Adapters
    # The `Flagging` port's adapter for `RedFlag`: raises, notes, checks in to and lowers the red
    # flag of a repository, reads its status, and surveys the latest CI run of main to raise or
    # lower it. The flag is `RedFlagMarker`'s file; nothing else is touched.
    class RedFlagging
      # The CI run id in a report such as `abc: CI run 12 failure; failed jobs: a, b`.
      RUN_ID = /run (\d+)/
      # The failed jobs in that report.
      JOBS = /failed jobs: (.*)\z/

      class << self
        # @return [#call, nil] takes `(argv, chdir:)` and answers `[ok, output]`; the command
        #   runner when nil. A spec replaces it with a fake GitHub.
        attr_accessor :runner
      end

      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      # @param registry [Runtime::Registry, nil] the booted registry a kick lands and files through
      # @param tune [Hash] `checkout:` the repository, `clock:`, `runner:` and `effects:`
      #   (the kick's steps, for a spec)
      def initialize(aggregate: nil, settings: {}, root: nil, registry: nil, **tune)
        @registry = registry
        @tune = tune
      end

      # Raises the flag for a red run, or notes the run on the flag that stands. A run the flag
      # already records is answered `idle`, so the same CI result may be reported twice.
      #
      # @param held [Hash] the `RedFlag` record: `commit`, `detail`, `work_items`, `checkout`
      # @return [Hash{Symbol => Hash}] `outcome:` (`raised`, `noted` or `idle`) and the flag's facts
      def hoist(**held)
        facts = run_facts(held)
        state, flag = marker(held).raise!(commit: pick(held, :commit, :landed).to_s, run: facts)
        return unchanged("run #{facts[:ci_run]} is already recorded on #{flag["id"]}") if state == :unchanged

        answer(state.to_s, flag, facts)
      end

      # The CI run, failed jobs, red Work items, last green head and repository of a red answer.
      def run_facts(held)
        detail = pick(held, :detail, :report).to_s
        { ci_run: detail[RUN_ID, 1], jobs: detail[JOBS, 1], work_items: plain(held[:work_items]),
          last_green: held[:last_green],
          checkout: checkout(held) }
      end

      # Reverts the push batch since the last green head off main, as a red-* fix, once the
      # flag has stood past the world's `kick_after_minutes` with no fix landed.
      #
      # @param held [Hash] the `RedFlag` record: `checkout` and `force` (kick before the time is up)
      # @return [Hash{Symbol => Hash}] `outcome:` (`kicked`), the flag's facts, `detail:` the
      #   reverted commits and `work_items:` the Work item filed to land them again
      # @raise [ConsoleCapture::Failure] when no flag stands, a fix is landed, the time is not up,
      #   the batch cannot be told, or a revert conflicts
      def evict(**held)
        kick = RedFlagKick.new(marker(held), checkout(held), registry: @registry, **@tune, runner: runner)
        kicked = kick.run(force: plain(held[:force]) == true)
        answer("kicked", kicked[:flag], detail: kicked[:reverted].join(", "), work_items: kicked[:row])
      end

      # @param held [Hash] the `RedFlag` record: `session`, `taking`, `checkout`
      # @return [Hash{Symbol => Hash}] `outcome:` (`checked_in`) and the flag's facts
      # @raise [ConsoleCapture::Failure] when no flag stands
      def sign_in(**held)
        flag = marker(held).check_in!(session: plain(held[:session]).to_s, taking: plain(held[:taking]).to_s)
        raise ConsoleCapture::Failure, "no red flag stands: nothing to check in to" unless flag

        answer("checked_in", flag, session: plain(held[:session]), taking: plain(held[:taking]))
      end

      # @param held [Hash] the `RedFlag` record: `checkout`
      # @return [Hash{Symbol => Hash}] `outcome:` (`cleared`, or `idle` when none stood)
      def lower(**held)
        flag = marker(held).clear!
        flag ? answer("cleared", flag, {}) : { outcome: { value: "idle" }, output: { value: "no red flag was standing" } }
      end

      # Reads the latest completed CI run of main and raises or lowers the flag to match it.
      #
      # @param held [Hash] the `RedFlag` record: `checkout`
      # @return [Hash{Symbol => Hash}] `outcome:` as {#hoist} and {#lower}, or `idle` while a run is
      #   still going
      def survey(**held)
        seen = RedFlagSurvey.new(runner: runner, checkout: checkout(held)).latest
        case seen[:verdict]
        when :red then hoist(**held, commit: seen[:commit], detail: seen[:detail], last_green: seen[:last_green])
        when :green then lower(**held)
        else unchanged(seen[:detail])
        end
      end

      # @param held [Hash] `checkout`
      # @return [Hash{Symbol => String}] `text:` the flag in words, or that none stands
      def status(**held)
        flag = marker(held).read
        { text: flag ? "#{RedFlagReport.new(flag).text}\n" : "main is not flagged\n" }
      end

      private

      def answer(outcome, flag, facts)
        { outcome: { value: outcome }, flag: { value: flag["id"] }, commit: { value: flag["commit"].to_s },
          ci_run: { value: facts[:ci_run].to_s }, jobs: { value: facts[:jobs].to_s },
          work_items: { value: facts[:work_items].to_s },
          session: { value: facts[:session].to_s }, taking: { value: facts[:taking].to_s },
          detail: { value: facts[:detail].to_s }, checkout: { value: facts[:checkout].to_s } }
      end

      def unchanged(why) = { outcome: { value: "idle" }, output: { value: why.to_s } }

      def runner = @tune[:runner] || self.class.runner

      def marker(held) = RedFlagMarker.new(git_dir(held), **@tune.slice(:clock))

      def git_dir(held)
        ok = Git.new.capture("rev-parse", "--path-format=absolute", "--git-common-dir", chdir: checkout(held))
        raise ConsoleCapture::Failure, "#{checkout(held)} is not a repository" unless ok.ok?

        ok.out.strip
      end

      def checkout(held) = plain(held[:checkout]) || @tune[:checkout] || Dir.pwd

      def pick(held, *keys) = plain(held[keys.find { |key| held.key?(key) }])

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
