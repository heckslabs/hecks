# frozen_string_literal: true

require "json"
require "time"
require_relative "../shell"
require_relative "../console_capture"
require_relative "brief_text"

module Hecks
  module Adapters
    class Dispatching
      # Starts one chosen work item's session by running the launcher's own commands, so each step
      # is the
      # bluebook's command and nothing is written but through one: start the Work item, compose its
      # brief, hand the brief to `AgentRun`. Before any of them, pull main (`LinkedTree.PullMain`),
      # so a session never starts from a stale base. A step that fails yields the work item to the
      # plan.
      class Launcher
        # The claimant every dispatched work item names.
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

        # @param work item [Plan::Item] the work item to start
        # @param held [Array<String>] a line for each area another started work item holds
        # @param frozen [Array<String>] the frozen areas and aggregates
        # @param minutes [Integer] the time budget of the work item
        # @param limit [Integer, nil] the most spec files a session runs per call, from the world
        # @return [String] one line: the session started, or why the work item went back to the plan
        def launch(item, held:, minutes:, limit: nil, **lines)
          step(item, "pull main", pull_argv)
          step(item, "start", start_argv(item, minutes))
          text = BriefText.new(composed(item)).render(item.key, area: item.area, limit: limit, held: held, **lines)
          step(item, "dispatch", dispatch_argv(item, text))
          "started #{item.key}"
        rescue ConsoleCapture::Failure => e
          yield_back(item, e.message)
        end

        # @param key [String] the run, which is also the Work item's key
        # @return [void]
        def check(key) = @runner.call(["AgentRun.check!", "to=#{key}", "--wait"])

        # @param key [String] the Work item to record as done
        # @return [String] the line that says so
        def finish(key)
          @runner.call(["tickets", "Work.finish!", "to=#{key}", "--wait"])
          "finished #{key}"
        end

        # @param key [String] the Work item to send back to the plan
        # @param reason [String] why
        # @return [String] the line that says so
        def yield_back(key, reason)
          key = key.key if key.respond_to?(:key)
          @runner.call(["tickets", "Work.yield!", "to=#{key}", "reason.value=#{reason}", "--wait"])
          "yielded #{key}: #{reason}"
        end

        private

        def step(item, name, argv)
          result = @runner.call(argv)
          return result if result.ok? && !result.out.include?('"refusal": "')

          raise ConsoleCapture::Failure, "#{name} of #{item.key} failed: #{said(result)}"
        end

        def said(result) = (result.err.empty? ? result.out : result.err).strip[0, 300]

        # Local `main` current before the session starts, so no worktree is cut from a stale base.
        def pull_argv = ["LinkedTree.pull_main!", "checkout.value=#{@repo}", "--wait"]

        def dispatch_argv(item, text)
          ["AgentRun.dispatch!", "run.value=#{item.key}", "repo.value=#{@repo}", "brief.value=#{text}", "--wait"]
        end

        def start_argv(item, minutes)
          ["tickets", "Work.start!", "to=#{item.key}", "claimed_by.value=#{CLAIMANT}", "claimed_at.value=#{Time.now.utc.iso8601}",
           *item.area.map { |word| "area.value=#{word}" }, "budget_minutes.value=#{minutes}", "--wait"]
        end

        def composed(item)
          argv = ["coder", "Brief.compose!", "work.value=#{item.key}", "outcome.value=#{item.title}",
                  "detail.value=#{item.detail}", *item.area.map { |word| "area.value=#{word}" }, "--wait"]
          result = step(item, "compose", argv)
          JSON.parse(result.out[JSON_OBJECT])["state"]
        end
      end
    end
  end
end
