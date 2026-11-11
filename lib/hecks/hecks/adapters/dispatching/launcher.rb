# frozen_string_literal: true

require "json"
require "time"
require_relative "../shell"
require_relative "../console_capture"
require_relative "brief_text"
require_relative "parking"
require_relative "step_outcome"

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

        # The part a Work item's run records for the board's role cards. It is not an agent, so the
        # session starts as `claude`'s default.
        WORKS_AS = "coder"

        # The words of the refusal a dispatch gets when a run already holds its key.
        KEY_HELD = /already[ _]recorded/

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
        # @param lines [Hash] `traps:` a line for each known trap the work item's area meets
        # @return [String] one line: the session started, with what a later reaction refused, or why
        #   the work item went back to the plan
        def launch(item, **asked) = attempt(item, **asked).last

        # Starts one work item like {#launch} and says how it ended, so a report counts outcomes
        # and never reads the text of a line.
        #
        # @param item [Plan::Item] the work item to start
        # @param held [Array<String>] a line for each area another started work item holds
        # @param minutes [Integer] the time budget of the work item
        # @param limit [Integer, nil] the most spec files a session runs per call
        # @param lines [Hash] `traps:` a line for each known trap the work item's area meets
        # @return [Array(Symbol, String)] `:started` or `:yielded`, then the line
        def attempt(item, held:, minutes:, limit: nil, **lines)
          step(item, "pull main", pull_argv)
          started = step(item, "start", start_argv(item, minutes), reaches: "started")
          text = BriefText.new(composed(item)).render(item.key, area: item.area, limit: limit, main: main, held: held, **lines)
          dispatch(item, text)
          [:started, started_line(item, started.note)]
        rescue ConsoleCapture::Failure => e
          [:yielded, yield_back(item, e.message)]
        end

        # Checks every started run's session in one launcher boot, so each run's change of state is
        # recorded however many runs are started.
        #
        # @return [void]
        def check_all = @runner.call(["AgentRun.check_all!", "--wait"])

        # Asks `AgentRun.Retire` to close the run named for a work item, which it does only when the
        # run's session is not listed by `claude agents`; a session still listed keeps its key.
        #
        # @param key [String] the run, which is also the Work item's key
        # @return [StepOutcome] what the command did; the run's status decides, since a run keeps
        #   the reason of an earlier refused retire after a later one succeeds
        def retire(key) = StepOutcome.new(@runner.call(retire_argv(key)), reaches: "retired", decided_by_status: true)

        # @param key [String] the Work item to record as done
        # @return [String] the line that says so
        def finish(key)
          @runner.call(["tickets", "Work.finish!", "to=#{key}", "--wait"])
          "finished #{key}"
        end

        # Files the finding that a session ended `done` while its Work item had landed nothing. The
        # work key is also the finding's key and fingerprint, so the same item filed again changes
        # nothing.
        #
        # @param key [String] the Work item whose session ended done with no landing
        # @return [String] the line that says so
        def report_unlanded(key)
          @runner.call(["tickets", "Finding.report!", "finding.value=unlanded-#{key}",
                        "title.value=#{key}: its session ended done and nothing landed", "source.value=settle",
                        "fingerprint.value=unlanded-#{key}", "--wait"])
          "reported unlanded-#{key}"
        end

        # @param key [Plan::Item, String] the Work item to send back to the plan; an item carries
        #   how many times it has yielded, so repeated failures back off longer, and a bare key
        #   counts as a first yield
        # @param reason [String] why
        # @return [String] the line that says so, and why the yield was not recorded when it was not
        def yield_back(key, reason, now: Time.now.utc)
          count = key.respond_to?(:yield_count) ? key.yield_count.to_i + 1 : 1
          key = key.key if key.respond_to?(:key)
          kind = Parking.classify(reason, count: count, now: now)
          outcome = StepOutcome.new(@runner.call(yield_argv(key, reason, kind, count)))
          line = "yielded #{key}: #{reason}"
          outcome.ok? ? line : "#{line} (the yield was not recorded: #{outcome.reason})"
        end

        private

        # The `Work.yield!` line: the reason, and the kind that says when to try the item again.
        def yield_argv(key, reason, kind, count)
          retry_at = kind.retry_at ? kind.retry_at.utc.iso8601 : ""
          ["tickets", "Work.yield!", "to=#{key}", "reason.value=#{reason}", "yield_kind.value=#{kind.name}",
           "retry_at.value=#{retry_at}", "yield_count.value=#{count}", "--wait"]
        end

        # Runs one step and answers its outcome; a step whose command did not do its part raises
        # with the command's own reason.
        def step(item, name, argv, reaches: nil)
          outcome = StepOutcome.new(@runner.call(argv), reaches: reaches)
          return outcome if outcome.ok?

          raise ConsoleCapture::Failure, "#{name} of #{item.key} failed: #{outcome.reason}"
        end

        # Hands the brief to `AgentRun`. A key held by a run still recorded started is refused; when
        # that run's session is gone, `AgentRun.Retire` closes it (it frees the key, as an ended
        # run does) and the dispatch is made once more. A session still listed keeps its key, so
        # the second refusal is the answer.
        def dispatch(item, text)
          step(item, "dispatch", dispatch_argv(item, text))
        rescue ConsoleCapture::Failure => e
          raise unless KEY_HELD.match?(e.message)

          retire_held(item, e)
          step(item, "dispatch", dispatch_argv(item, text))
        end

        # Retires the run that holds the key before the second dispatch. A retire the domain refuses
        # ends the launch, naming both refusals, so the yield says why the key stayed held.
        def retire_held(item, held)
          outcome = retire(item.key)
          return if outcome.ok?

          raise ConsoleCapture::Failure, "#{held.message} (retire of #{item.key} refused: #{outcome.reason})"
        end

        def retire_argv(key) = ["AgentRun.retire!", "to=#{key}", "--wait"]

        def started_line(item, note) = note.empty? ? "started #{item.key}" : "started #{item.key} (then refused: #{note})"

        # Local `main` current before the session starts, so no worktree is cut from a stale base.
        def pull_argv = ["LinkedTree.pull_main!", "checkout.value=#{@repo}", "--wait"]

        def dispatch_argv(item, text)
          ["AgentRun.dispatch!", "run.value=#{item.key}", "repo.value=#{@repo}", "works_as.value=#{WORKS_AS}",
           "brief.value=#{text}", "--wait"]
        end

        def start_argv(item, minutes)
          ["tickets", "Work.start!", "to=#{item.key}", "claimed_by.value=#{CLAIMANT}", "claimed_at.value=#{Time.now.utc.iso8601}",
           *item.area.map { |word| "area.value=#{word}" }, "budget_minutes.value=#{minutes}", "--wait"]
        end

        # The primary checkout a brief's `{main}` names: where the reviews and red flags are stored.
        def main = File.expand_path(@repo)

        def composed(item)
          argv = ["coder", "Brief.compose!", "work.value=#{item.key}", "outcome.value=#{item.title}",
                  "detail.value=#{item.detail}", *item.area.map { |word| "area.value=#{word}" }, "--wait"]
          state = step(item, "compose", argv).printed&.dig("state")
          state || raise(ConsoleCapture::Failure, "compose of #{item.key} printed no brief")
        end
      end
    end
  end
end
