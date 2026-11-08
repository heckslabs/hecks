# frozen_string_literal: true

require_relative "../git_worktrees"
require_relative "../git_main_pull"
require_relative "../shell"
require_relative "../git_shallow_check"

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

        # The command that runs the seconds-long checks in a worktree.
        GATE = %w[exe/hecks gate_run.gate! stage=quick --wait].freeze

        # What a completed gate run prints.
        COMPLETED = /"status":\s*"completed"/

        # @param git [Git] the adapter every git call goes through
        # @param checkout [String] the worktree the branch is checked out in
        # @param branch [String] the branch to finish
        # @param onto [String] the branch to rebase onto
        # @param steps [Hash] `gate:` (answers the {Shell::Result} of the quick gate run in a
        #   directory) and `shallow:` (given the checkout, branch and onto, raises when one of CI's
        #   failing checks is red in a depth-1 clone)
        def initialize(git, checkout, branch:, onto:, **steps)
          @git = git
          @checkout = checkout
          @branch = ref(branch)
          @onto = ref(onto)
          @gate = steps[:gate] || ->(dir) { Shell.new.capture(*GATE, chdir: dir) }
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

        def run_gate
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
