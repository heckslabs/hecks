# frozen_string_literal: true

require_relative "../git_worktrees"
require_relative "../git_main_pull"
require_relative "../shell"

module Hecks
  module Adapters
    class GitLanding
      # The steps before a landing, taken in one go: refuse unsaved work, rebase the branch onto
      # local `main`, and run the quick gate in the branch's worktree.
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
        # @param gate [#call] answers the {Shell::Result} of the quick gate run in a directory
        def initialize(git, checkout, branch:, onto:, gate: nil)
          @git = git
          @checkout = checkout
          @branch = ref(branch)
          @onto = ref(onto)
          @gate = gate || ->(dir) { Shell.new.capture(*GATE, chdir: dir) }
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
        end

        private

        def refuse_unsaved
          changed = dirty(@checkout)
          raise ConsoleCapture::Failure, "unsaved work: #{@checkout} holds #{changed.join(", ")}" unless changed.empty?
        end

        def rebase
          result = @git.capture("rebase", @onto, chdir: @checkout)
          return if result.ok?

          conflicts = @git.capture("diff", "--name-only", "--diff-filter=U", chdir: @checkout).out.split
          @git.capture("rebase", "--abort", chdir: @checkout)
          raise ConsoleCapture::Failure,
                "conflict: rebasing #{@branch} onto #{@onto} conflicts in #{conflicts.join(", ")}; nothing changed"
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
