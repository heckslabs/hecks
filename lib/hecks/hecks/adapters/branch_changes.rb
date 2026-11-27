# frozen_string_literal: true

require_relative "shell"
require_relative "branch_pruning/reading"

module Hecks
  module Adapters
    # The files a branch changes against the branch it is measured from, names only: the one read
    # the fill's ground ({Dispatching::EffectiveArea}) and the impediment view
    # ({StallWatching::OpenBranches}) share. It is the diff a landing's clash check reads
    # (`GitLanding::Rivals`), so a rename counts alike everywhere. Each branch is read once.
    class BranchChanges
      # @param repo [String] a checkout of the repository whose branches are read
      # @param onto [String] the branch a branch's changes are measured from
      # @param shell [Shell] runs git
      # @param unlanded [Boolean] read only the files of commits `onto` lacks by patch (`git
      #   cherry`), so work `onto` holds under other hashes counts for nothing; a merge commit
      #   adds no file of its own
      def initialize(repo, onto: "main", shell: Shell.new, unlanded: false)
        @repo = repo
        @onto = onto
        @unlanded = unlanded
        @shell = shell
        @seen = {}
      end

      # @param branch [String] a local branch
      # @return [Array<String>] the files it changes since it left `onto`; none when git cannot
      #   read the branch
      def of(branch)
        @seen[branch] ||= @unlanded ? unlanded_files(branch) : names(
          "diff", "--no-renames", "--name-only", "-z", "#{@onto}...refs/heads/#{branch}"
        )
      end

      private

      def unlanded_files(branch)
        cherry = @shell.capture("git", "cherry", @onto, "refs/heads/#{branch}", chdir: @repo)
        return [] unless cherry.ok?

        cherry.out.lines.filter_map { |line| line[BranchPruning::Reading::UNLANDED_COMMIT, 1] }
               .flat_map { |sha| names("diff-tree", "--no-commit-id", "--no-renames", "--name-only", "-r", "-z", sha) }.uniq
      end

      def names(*argv)
        result = @shell.capture("git", *argv, chdir: @repo)
        result.ok? ? result.out.split("\0").reject(&:empty?) : []
      end
    end
  end
end
