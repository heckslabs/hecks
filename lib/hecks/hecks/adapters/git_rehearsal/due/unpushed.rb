# frozen_string_literal: true

require_relative "../reading"

module Hecks
  module Adapters
    class GitRehearsal
      class Due
        # The commits local `main` holds that `origin/main` does not, newest first: each one's
        # short sha, subject and age in hours, at most `LIMIT` of them, then how many more.
        class Unpushed
          include Reading

          # The most commits listed; the rest are counted.
          LIMIT = 10

          # @param git [Git] the adapter every git call goes through
          # @param checkout [String] the repository's top level
          # @param range [String] the revision range, `origin/main..main`
          # @param clock [#now] where the ages are read from
          def initialize(git, checkout, range:, clock:)
            @git = git
            @checkout = checkout
            @range = range
            @clock = clock
          end

          # @return [Array<String>] "unpushed:" and one indented line per commit, or none when
          #   the range is empty
          def lines
            commits = read("log", "--format=%H%x09%ct%x09%s", @range).lines
            return [] if commits.empty?

            ["unpushed:", *commits.first(LIMIT).map { |entry| line(entry) }, *rest(commits.size)]
          end

          private

          def line(entry)
            commit, stamp, subject = entry.chomp.split("\t", 3)
            "  #{short(commit)} #{subject} (#{Due.hours(@clock, stamp)} hours old)"
          end

          def rest(count) = count > LIMIT ? ["  and #{count - LIMIT} more"] : []
        end
      end
    end
  end
end
