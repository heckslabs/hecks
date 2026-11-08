# frozen_string_literal: true

require_relative "git_worktrees"
require_relative "git_shallow_check/trigger"
require_relative "git_shallow_check/switch"
require_relative "git_shallow_check/clone_run"

module Hecks
  module Adapters
    # The `ShallowChecks` port's adapter for `ShallowCheck`: runs CI's failing checks in a fresh
    # `--depth 1` clone of a branch tip, when the branch changes something those checks read.
    #
    # It never writes to the repository it reads. The clone lives in a temporary directory and is
    # removed whether the checks pass or not.
    class GitShallowCheck
      include GitWorktrees

      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      # @param registry [Runtime::Registry, nil] unused
      # @param run [Hash] what a spec changes in the clone run: `specs:` and `command:`
      def initialize(aggregate: nil, settings: {}, root: nil, registry: nil, **run)
        @git = Git.new
        @run = run
      end

      # Runs the checks for a branch, or says why they were skipped.
      #
      # @param held [Hash] the `ShallowCheck` record: `checkout`, `branch`, `onto`
      # @return [Hash{Symbol => Hash}] `report:` what ran or why nothing did
      # @raise [ConsoleCapture::Failure] naming the spec and its first failure line
      def shallow_check(**held)
        settle(held)
        branch = plain(held[:branch]) || current_branch
        onto = plain(held[:onto]) || "main"
        return { report: { value: "shallow check is off" } } unless switch.on?

        { report: { value: verdict(branch, ref(onto)) } }
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

      def verdict(branch, onto)
        paths = read("diff", "--name-only", "#{onto}...#{ref(branch)}").lines.map(&:strip)
        return "shallow check skipped: no changed path is read by the check set" if Trigger.watched(paths).empty?

        refusal = CloneRun.new(@checkout, branch, **@run).call(fuzz: fuzz_for(paths))
        raise ConsoleCapture::Failure, "shallow check red: #{refusal}" if refusal

        "shallow check green: #{@run.fetch(:specs, CloneRun::SPECS).size} specs in a depth-1 clone of #{branch}"
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
