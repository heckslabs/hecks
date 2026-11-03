# frozen_string_literal: true

require_relative "../git_worktrees"
require_relative "../area_overlap"
require_relative "../started_work"

module Hecks
  module Adapters
    class GitLanding
      # The started Work items that hold ground a branch changes. A branch is landed for its own
      # Work
      # work item, the one keyed by the branch name, so that work item is never a rival; a landing
      # with no work item
      # has none to clash with.
      class Rivals
        include GitWorktrees

        # @param git [Git] the adapter every git call goes through
        # @param checkout [String] the repository's top level
        # @param registry [Runtime::Registry, nil] where the Work items are read from
        def initialize(git, checkout, registry)
          @git = git
          @checkout = checkout
          @registry = registry
        end

        # @param branch [String] the branch to land
        # @param onto [String] the branch it lands on
        # @return [String, nil] the refusal naming the work item and the files, nil when none clash
        def refusal(branch, onto)
          files = changed(branch, onto)
          StartedWork.items(@registry).each do |item|
            next if item[:key] == branch

            clash = files.select { |file| claims?(item, file) }
            return wording(branch, item, clash) unless clash.empty?
          end
          nil
        end

        private

        def claims?(item, file)
          item[:area].any? { |area| AreaOverlap.overlap?(area, file, root: @checkout, file: true) }
        end

        def wording(branch, item, clash)
          "#{branch} changes #{clash.join(", ")}, in the area of #{item[:key]} (#{item[:area].join(", ")})"
        end

        def changed(branch, onto)
          result = @git.capture("diff", "--no-renames", "--name-only", "-z", "#{ref(onto)}...#{ref(branch)}",
                                chdir: @checkout)
          raise ConsoleCapture::Failure, "git diff failed in #{@checkout}: #{result.err.strip}" unless result.ok?

          result.out.split("\0").reject(&:empty?)
        end
      end
    end
  end
end
