# frozen_string_literal: true

require_relative "../reading"

module Hecks
  module Adapters
    class GitRehearsal
      class Due
        # What `origin/main` holds as this repository last saw it: the commits local `main`
        # lacks, when the remote-tracking branch last moved (its reflog, written by the fetch or
        # push that moved it), and the last train, the tip it carried. Nothing is fetched.
        class Remote
          include Reading

          # @param git [Git] the adapter every git call goes through
          # @param checkout [String] the repository's top level
          # @param place [Hash] `branch:` the local branch, `tracking:` its remote-tracking branch
          # @param clock [#now] where the ages are read from
          def initialize(git, checkout, clock:, **place)
            @git = git
            @checkout = checkout
            @clock = clock
            @branch = place.fetch(:branch)
            @tracking = place.fetch(:tracking)
          end

          # @return [Array<String>] the behind line and the last train line
          def lines = [behind, last_train]

          private

          def behind
            count = read("rev-list", "--count", "#{@branch}..#{@tracking}").to_i
            "behind: #{count} commit(s) on #{@tracking} that #{@branch} lacks; #{moved}"
          end

          def moved
            stamp = read("reflog", "-1", "--format=%ct", "refs/remotes/#{@tracking}")
            return "when #{@tracking} last moved is not recorded here" if stamp.empty?

            "#{@tracking} last moved #{Due.hours(@clock, stamp)} hours ago (nothing is fetched now)"
          end

          def last_train
            commit, stamp, subject = read("log", "-1", "--format=%H%x09%ct%x09%s", @tracking).split("\t", 3)
            "last train: #{short(commit)} #{subject}, #{Due.hours(@clock, stamp)} hours ago " \
              "(the tip of #{@tracking}, what the last boarding carried)"
          end
        end
      end
    end
  end
end
