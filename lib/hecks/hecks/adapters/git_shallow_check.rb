# frozen_string_literal: true

require_relative "git_worktrees"
require_relative "git_shallow_check/trigger"
require_relative "git_shallow_check/switch"
require_relative "git_shallow_check/clone_run"
require_relative "git_shallow_check/on_main"
require_relative "git_shallow_check/impacted_run"

module Hecks
  module Adapters
    # The `ShallowChecks` port's adapter for `ShallowCheck`: runs CI's failing checks in a fresh
    # `--depth 1` clone of a branch tip, when the branch changes something those checks read. A
    # red is compared with a depth-1 clone of the branch it lands on: only a spec green there
    # refuses.
    #
    # It never writes to the repository it reads. The clone lives in a temporary directory and is
    # removed whether the checks pass or not.
    class GitShallowCheck
      include GitWorktrees

      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      # @param registry [Runtime::Registry, nil] unused
      # @param run [Hash] what a spec changes in the clone run: `specs:` and `command:`;
      #   `impacted:` stands in for the impacted-spec run, given the changed paths and the ref
      #   they were read against, and answers an {ImpactedRun::Outcome}
      def initialize(aggregate: nil, settings: {}, root: nil, registry: nil, **run)
        @git = Git.new
        @impacted = run.delete(:impacted)
        @run = run
      end

      # Runs the checks for a branch, or says why they were skipped, then the specs its changes
      # touch within the world's `impacted_seconds`.
      #
      # @param held [Hash] the `ShallowCheck` record: `checkout`, `branch`, `onto`
      # @return [Hash{Symbol => Hash}] `report:` what ran or why nothing did, and `unrun:` the
      #   impacted specs the budget left, with the seconds spent, when it ran out
      # @raise [ConsoleCapture::Failure] naming the failed specs, the first failure's message and
      #   whether the branch it lands on fails them too, or the impacted spec that is red
      def shallow_check(**held)
        settle(held)
        branch = plain(held[:branch]) || current_branch
        onto = ref(plain(held[:onto]) || "main")
        paths = read("diff", "--name-only", "#{onto}...#{ref(branch)}").lines.map(&:strip)
        said = switch.on? ? verdict(branch, onto, paths) : "shallow check is off"
        impacted(said, paths, onto)
      end

      # Turns the check on or off for the whole repository.
      #
      # @param held [Hash] `checkout` and `state` (`on` or `off`)
      # @return [Hash{Symbol => Hash}] `report:` the state now in force
      # @raise [ConsoleCapture::Failure] for any other state
      def shallow_switch(**held)
        settle(held)
        { report: { value: "shallow check is #{switch.set(plain(held[:state]))}" } }
      rescue ArgumentError => e
        raise ConsoleCapture::Failure, e.message
      end

      private

      def switch = Switch.new(read("rev-parse", "--path-format=absolute", "--git-common-dir"))

      # Runs the impacted specs after the shallow verdict; a red one raises, an overrun is answered.
      def impacted(said, paths, onto)
        done = (@impacted || ImpactedRun.new(@checkout)).call(paths, onto)
        note = "impacted specs: #{done.ran.size} ran in #{done.seconds} s"
        answer = { report: { value: "#{said}; #{note}" } }
        return answer if done.unrun.empty?

        answer.merge(unrun: { value: "#{done.unrun.join(" ")} (not run: #{done.seconds} s spent of the budget)" })
      end

      def verdict(branch, onto, paths)
        return "shallow check skipped: no changed path is read by the check set" if Trigger.watched(paths).empty?

        red = CloneRun.new(@checkout, branch, **@run).call(fuzz: fuzz_for(paths))
        red ? compared(OnMain.new(@checkout, onto, red, **@run)) : green(branch)
      end

      def green(branch)
        "shallow check green: #{@run.fetch(:specs, CloneRun::SPECS).size} specs in a depth-1 clone of #{branch}"
      end

      # A spec red where the branch lands too is reported, not refused: the branch did not cause it.
      def compared(on_main)
        return "shallow check passed: #{on_main}" if on_main.excused?

        raise ConsoleCapture::Failure, "shallow check red: #{on_main}"
      end

      def fuzz_for(paths)
        lambda do |clone|
          require "hecks/corpus"
          Trigger.fuzzed(paths, Hecks::Corpus.fuzzable_domains(clone), clone)
        end
      end
    end
  end
end
