# frozen_string_literal: true

require_relative "git"
require_relative "console_capture"
require_relative "red_flag_marker"
require_relative "red_flag_report"
require_relative "red_flag_survey"

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

      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      # @param tune [Hash] `checkout:` the repository, `clock:` and `runner:` (for a spec)
      def initialize(aggregate: nil, settings: {}, root: nil, **tune)
        @tune = tune
      end

      # @param held [Hash] the `RedFlag` record: `commit`, `detail`, `rows`, `checkout`
      # @return [Hash{Symbol => Hash}] `outcome:` (`raised` or `noted`) and the flag's facts
      def hoist(**held)
        detail = pick(held, :detail, :report).to_s
        facts = { ci_run: detail[RUN_ID, 1], jobs: detail[JOBS, 1], rows: plain(held[:rows]) }
        state, flag = marker(held).raise!(commit: pick(held, :commit, :landed).to_s, run: facts)
        answer(state.to_s, flag, facts)
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
        seen = RedFlagSurvey.new(runner: @tune[:runner], checkout: checkout(held)).latest
        return hoist(commit: seen[:commit], detail: seen[:detail]) if seen[:verdict] == :red
        return lower(**held) if seen[:verdict] == :green

        { outcome: { value: "idle" }, output: { value: seen[:detail] } }
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
          ci_run: { value: facts[:ci_run].to_s }, jobs: { value: facts[:jobs].to_s }, rows: { value: facts[:rows].to_s },
          session: { value: facts[:session].to_s }, taking: { value: facts[:taking].to_s } }
      end

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
