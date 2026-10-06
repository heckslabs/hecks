# frozen_string_literal: true

require_relative "gate"

module Hecks
  module Adapters
    module Codebase
      module Promotion
        # The commits a lane could move onto, and which of them have been certified.
        #
        # A commit is certified when every `RequiredCheck` passed against that exact commit; the
        # checks of its neighbours say nothing about it. Promotion is therefore a question about the
        # whole stretch of the followed lane the promoted lane has not reached, not about whichever
        # commit happened to finish last: when the newest commit is red or still running, an older
        # one that passed is still worth promoting, and a promotion run that was dropped or
        # beaten to the lane costs nothing, because the next one finds the same answer.
        class Candidates
          # How far back from the followed lane's head to look for a certified commit.
          LIMIT = 25

          # @param repo [#recent_commits, #ancestor?] the `Git` adapter
          # @param where [String] a directory inside the repository
          # @param source_head [String] where the followed lane stands
          # @param head [String, nil] where the promoted lane stands, nil when it does not exist yet
          def initialize(repo, where, source_head, head)
            @repo = repo
            @where = where
            @source_head = source_head
            @head = head
          end

          # @return [Array<String>] the commits the promoted lane lacks, newest first, each one a
          #   fast-forward of the lane
          def commits
            @commits ||= @repo.recent_commits(@source_head, older: @head, limit: LIMIT, chdir: @where)
                              .select { |commit| forward?(commit) }
          end

          # @return [String, nil] the newest commit every required check passed on, nil when none
          #   did
          def newest_certified = commits.find { |commit| gate(commit).green? }

          # @param commit [String] a commit
          # @return [Gate] where the required checks stand against it; asked once per commit
          def gate(commit) = (@gates ||= {})[commit] ||= Gate.new(commit)

          private

          def forward?(commit) = @head.nil? || @repo.ancestor?(@head, commit, chdir: @where)
        end
      end
    end
  end
end
