# frozen_string_literal: true

require_relative "../git_worktrees"
require_relative "../git_main_pull"
require_relative "../shell"
require_relative "../git_shallow_check"
require_relative "../checkout_gate"
require_relative "bound_gate"

module Hecks
  module Adapters
    class GitLanding
      # The steps before a landing that an agent runs by hand: refuse unsaved work, rebase the
      # branch onto local `main`, and run the quick gate in the branch's worktree.
      #
      # Each step refuses by name at the first failure, with the reason, and leaves the branch as it
      # was: a rebase that conflicts is aborted. The landing itself and the tidy after it are
      # {GitLanding#merge}'s.
      class Finisher
        include GitWorktrees
        include GitMainPull

        # What a completed run of a stand-in launcher prints.
        COMPLETED = CheckoutGate::COMPLETED

        # Runs the steps for a landing's record, judged by the project's gate unless the record
        # hands a stand-in.
        #
        # @param git [Git] the adapter every git call goes through
        # @param checkout [String] the worktree the branch is checked out in
        # @param held [Hash] the `Landing` record, which may hold `gate:` and `shallow:` stand-ins
        # @param registry [Runtime::Registry, nil] the booted registry
        # @param place [Hash] `branch:` (the one to finish) and `onto:` (the one to rebase onto)
        # @return [void]
        # @raise [ConsoleCapture::Failure] as {#prepare}
        def self.prepare(git, checkout, held, registry:, **place)
          new(git, checkout, registry: registry, gate: held[:gate], shallow: held[:shallow], **place).prepare
        end

        # @param git [Git] the adapter every git call goes through
        # @param checkout [String] the worktree the branch is checked out in
        # @param branch [String] the branch to finish
        # @param onto [String] the branch to rebase onto
        # @param steps [Hash] `registry:` (the booted registry, whose `Gate` port's adapter judges
        #   the worktree), `gate:` (a stand-in for that adapter: answers the {Shell::Result} of a
        #   gate run in a directory) and `shallow:` (given the checkout, branch and onto, raises
        #   when one of CI's failing checks is red in a depth-1 clone)
        def initialize(git, checkout, branch:, onto:, **steps)
          @git = git
          @checkout = checkout
          @branch = ref(branch)
          @onto = ref(onto)
          @gate = steps[:gate]
          @bound = BoundGate.new(steps[:registry])
          @shallow = steps[:shallow] || method(:shallow_check)
        end

        # Refuses unsaved work, pulls `main` when it is the target, rebases and runs the gate.
        #
        # @return [void]
        # @raise [ConsoleCapture::Failure] naming the step that failed: unsaved work, conflict or
        #   gate red
        def prepare
          refuse_unsaved
          pull_main if @onto == "main"
          rebase
          run_gate
          @shallow.call(@checkout, @branch, @onto)
        end

        private

        def shallow_check(checkout, branch, onto)
          GitShallowCheck.new.shallow_check(checkout: checkout, branch: branch, onto: onto)
        end

        def refuse_unsaved
          changed = dirty(@checkout)
          raise ConsoleCapture::Failure, "unsaved work: #{@checkout} holds #{changed.join(", ")}" unless changed.empty?
        end

        def rebase
          result = @git.capture(*replay_identity(@checkout), "rebase", *rebase_range, chdir: @checkout)
          return if result.ok?

          raise ConsoleCapture::Failure,
                "conflict: rebasing #{@branch} onto #{@onto} #{abandon_rebase(@checkout, result)}; nothing changed"
        end

        # What the rebase replays: when the branch was cut from a commit that `onto` carried by
        # squash, only the branch's own commits after it.
        def rebase_range
          boarded = carried_boarding("#{@branch}..#{@onto}", @branch)
          boarded ? ["--onto", @onto, boarded] : [@onto]
        end

        # Asks the project's gate, or the stand-in a caller handed over, and refuses when it is red.
        def run_gate
          return run_stand_in if @gate

          why = @bound.refusal(@checkout)
          raise ConsoleCapture::Failure, why if why
        end

        def run_stand_in
          result = @gate.call(@checkout)
          return if result.ok? && result.out.match?(COMPLETED)

          raise ConsoleCapture::Failure, "gate red: the quick gate failed in #{@checkout}: #{tail(result)}"
        end

        def tail(result)
          lines = result.out.lines.last(5)
          lines.join.strip
        end
      end
    end
  end
end
