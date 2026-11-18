# frozen_string_literal: true

require "time"

module Hecks
  module Adapters
    class GithubBranchCi
      # The report a coder reads of one run: how long it queued and took, the branch's own failed
      # jobs with the last lines of each log, and apart from them the jobs that failed on the
      # branch's base too, with the word that a red main is the orchestrator's to fix.
      class Summary
        # The failed log lines a report keeps of each job, from its end.
        LINES = 5

        # @param run [Hash] the ended run
        # @param pushed_at [Time] when the branch was pushed
        def initialize(run, pushed_at)
          @run = run
          @pushed_at = pushed_at
        end

        # @param own [Array<Failures::Failure>] the jobs that failed on the branch alone
        # @param inherited [Array<Failures::Failure>] the jobs that failed on its base too
        # @param base [Hash, nil] the base's run (`run`, `sha`), nil when none could be read
        # @return [String] the report, one line per part
        def text(own, inherited, base)
          lines = ["CI run #{@run["id"]} (#{@run["html_url"]}): #{@run["conclusion"]}; #{timing}"]
          lines << (own.empty? ? "own failures: none" : "own failures:")
          lines.concat(own.map { |failure| "#{failure.name}: #{tail(failure)}" })
          (lines + base_lines(own + inherited, inherited, base)).join("\n")
        end

        private

        def base_lines(failed, inherited, base)
          return [] if failed.empty?
          return ["no CI run of the branch's base was read: every failure is the branch's own"] unless base
          return [] if inherited.empty?

          ["inherited from main (run #{base[:run]} at #{base[:sha].to_s[0, 10]}):"] +
            inherited.map { |failure| "#{failure.name} [#{failure.examples.join(", ")}]" } +
            ["main is red at the branch's base: hand off clean work; the red main's fix is the orchestrator's"]
        end

        def timing
          created, started, ended = %w[created_at run_started_at updated_at].map { |key| Time.parse(@run[key].to_s) }
          "queued #{(started - created).round}s, push to end #{((ended - @pushed_at) / 60).round(1)} min"
        rescue ArgumentError
          "times unread"
        end

        def tail(failure)
          return "log unread" unless failure.log

          last = failure.log.lines.last(LINES)
          last.map(&:strip).join(" | ")
        end
      end
    end
  end
end
