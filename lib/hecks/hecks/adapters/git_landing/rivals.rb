# frozen_string_literal: true

require_relative "../git_worktrees"
require_relative "../area_overlap"
require_relative "../started_work"

module Hecks
  module Adapters
    class GitLanding
      # The started Work rows that hold ground a branch changes. A branch is landed for its own Work
      # row, the one keyed by the branch name, so that row is never a rival; a landing with no row
      # has none to clash with.
      class Rivals
        include GitWorktrees

        # @param git [Git] the adapter every git call goes through
        # @param checkout [String] the repository's top level
        # @param registry [Runtime::Registry, nil] where the Work rows are read from
        def initialize(git, checkout, registry)
          @git = git
          @checkout = checkout
          @registry = registry
        end

        # @param branch [String] the branch to land
        # @param onto [String] the branch it lands on
        # @return [String, nil] the refusal naming the row and the files, nil when none clash
        def refusal(branch, onto)
          files = changed(branch, onto)
          StartedWork.rows(@registry).each do |row|
            next if row[:key] == branch

            clash = files.select { |file| row[:area].any? { |area| AreaOverlap.overlap?(area, file) } }
            return wording(branch, row, clash) unless clash.empty?
          end
          nil
        end

        private

        def wording(branch, row, clash)
          "#{branch} changes #{clash.join(", ")}, in the area of #{row[:key]} (#{row[:area].join(", ")})"
        end

        def changed(branch, onto)
          read("diff", "--name-only", "#{ref(onto)}...#{ref(branch)}").split("\n")
        end
      end
    end
  end
end
