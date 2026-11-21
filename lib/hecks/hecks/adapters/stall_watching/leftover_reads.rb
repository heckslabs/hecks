# frozen_string_literal: true

require_relative "../shell"

module Hecks
  module Adapters
    class StallWatching
      # The counts of what a clean-up has not removed, each read once and cheaply: finished sessions
      # the tap shows no `AgentRunTidied` for, worktrees beside the main checkout, and local
      # branches merged into main. It reads the tap's lines and git, and changes nothing.
      class LeftoverReads
        # @param lines [Array<Hash>] tap lines in sequence order
        # @param repo [String] a checkout of the repository
        # @param shell [Shell] runs git
        def initialize(lines, repo, shell: Shell.new)
          @lines = lines
          @repo = repo
          @shell = shell
        end

        # @param name [String] "finished-sessions", "worktrees" or "merged-branches"
        # @return [Integer] how many stand; nought when git cannot say
        # @raise [ArgumentError] for any other name
        def call(name)
          case name
          when "finished-sessions" then finished
          when "worktrees" then git("worktree", "list", "--porcelain").count { |line| line.start_with?("worktree ") } - 1
          when "merged-branches" then git("branch", "--merged", "main", "--format=%(refname:short)").count { |b| b != "main" }
          else raise ArgumentError, "unknown leftover #{name.inspect}"
          end.clamp(0, nil)
        end

        private

        def finished
          runs = @lines.select { |line| line["aggregate"] == "Hecks::AgentRun" }
          standing = runs.each_with_object(Set.new) do |line, ids|
            ids << line["id"] if line["event"] == "SessionFinished"
            ids.delete(line["id"]) if line["event"] == "AgentRunTidied"
          end
          standing.size
        end

        def git(*)
          result = @shell.capture("git", *, chdir: @repo)
          result.ok? ? result.out.lines.map(&:chomp) : []
        end
      end
    end
  end
end
