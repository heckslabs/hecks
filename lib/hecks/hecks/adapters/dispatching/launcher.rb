# frozen_string_literal: true

require "json"
require "time"
require_relative "../shell"
require_relative "../console_capture"
require_relative "brief_text"

module Hecks
  module Adapters
    class Dispatching
      # Starts one chosen row's session by running the launcher's own commands, so each step is the
      # bluebook's command and nothing is written but through one: start the Work row, compose its
      # brief, hand the brief to `AgentRun`. Before any of them, pull main (`LinkedTree.PullMain`),
      # so a session never starts from a stale base. A step that fails yields the row to the plan.
      class Launcher
        # The claimant every dispatched row names.
        CLAIMANT = "dispatch"

        # The JSON object a command prints after any log lines.
        JSON_OBJECT = /\{.*\}/m

        # @param repo [String] the checkout whose `exe/hecks` runs the commands and where sessions
        #   work
        # @param runner [#call, nil] runs an argument list in `repo` and answers a {Shell::Result}
        def initialize(repo, runner: nil)
          @repo = repo
          @runner = runner || ->(argv) { Shell.new.capture("exe/hecks", *argv, chdir: repo) }
        end

        # @param row [Plan::Row] the row to start
        # @param held [Array<String>] a line for each area another started row holds
        # @param frozen [Array<String>] the frozen areas and aggregates
        # @param minutes [Integer] the time budget of the row
        # @param limit [Integer, nil] the most spec files a session runs per call, from the world
        # @return [String] one line: the session started, or why the row went back to the plan
        def launch(row, held:, minutes:, limit: nil, **lines)
          step(row, "pull main", pull_argv)
          step(row, "start", start_argv(row, minutes))
          text = BriefText.new(composed(row)).render(row.key, area: row.area, limit: limit, held: held, **lines)
          step(row, "dispatch", dispatch_argv(row, text))
          "started #{row.key}"
        rescue ConsoleCapture::Failure => e
          yield_back(row, e.message)
        end

        # @param key [String] the run, which is also the Work row's key
        # @return [void]
        def check(key) = @runner.call(["AgentRun.check!", "to=#{key}", "--wait"])

        # @param key [String] the Work row to record as done
        # @return [String] the line that says so
        def finish(key)
          @runner.call(["tickets", "Work.finish!", "to=#{key}", "--wait"])
          "finished #{key}"
        end

        # @param key [String] the Work row to send back to the plan
        # @param reason [String] why
        # @return [String] the line that says so
        def yield_back(key, reason)
          key = key.key if key.respond_to?(:key)
          @runner.call(["tickets", "Work.yield!", "to=#{key}", "reason.value=#{reason}", "--wait"])
          "yielded #{key}: #{reason}"
        end

        private

        def step(row, name, argv)
          result = @runner.call(argv)
          return result if result.ok? && !result.out.include?('"refusal": "')

          raise ConsoleCapture::Failure, "#{name} of #{row.key} failed: #{said(result)}"
        end

        def said(result) = (result.err.empty? ? result.out : result.err).strip[0, 300]

        # Local `main` current before the session starts, so no worktree is cut from a stale base.
        def pull_argv = ["LinkedTree.pull_main!", "checkout.value=#{@repo}", "--wait"]

        def dispatch_argv(row, text)
          ["AgentRun.dispatch!", "run.value=#{row.key}", "repo.value=#{@repo}", "brief.value=#{text}", "--wait"]
        end

        def start_argv(row, minutes)
          ["tickets", "Work.start!", "to=#{row.key}", "claimed_by.value=#{CLAIMANT}", "claimed_at.value=#{Time.now.utc.iso8601}",
           *row.area.map { |word| "area.value=#{word}" }, "budget_minutes.value=#{minutes}", "--wait"]
        end

        def composed(row)
          result = step(row, "compose", ["coder", "Brief.compose!", "work.value=#{row.key}", "outcome.value=#{row.title}",
                                         "detail.value=#{row.detail}", *row.area.map { |word| "area.value=#{word}" }, "--wait"])
          JSON.parse(result.out[JSON_OBJECT])["state"]
        end
      end
    end
  end
end
