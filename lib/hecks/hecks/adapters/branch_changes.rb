# frozen_string_literal: true

require_relative "shell"

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
      def initialize(repo, onto: "main", shell: Shell.new)
        @repo = repo
        @onto = onto
        @shell = shell
        @seen = {}
      end

      # @param branch [String] a local branch
      # @return [Array<String>] the files it changes since it left `onto`; none when git cannot
      #   read the branch
      def of(branch)
        @seen[branch] ||= begin
          result = @shell.capture("git", "diff", "--no-renames", "--name-only", "-z",
                                  "#{@onto}...refs/heads/#{branch}", chdir: @repo)
          result.ok? ? result.out.split("\0").reject(&:empty?) : []
        end
      end
    end
  end
end
