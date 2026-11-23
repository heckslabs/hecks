# frozen_string_literal: true

require "time"
require "hecks/hecks/adapters/git"

module Hecks
  module Adapters
    class Velocity
      # The span of a work item's branch read from git: the seconds from its first commit to the
      # merge of the branch into `main`. The branch is named as the work item's key.
      class GitSpan
        # @param checkout [String, nil] the checkout whose history is read
        def initialize(checkout = nil)
          @checkout = checkout
          @git = Git.new
        end

        # @param key [String] the work item's key, which names its branch
        # @return [Integer, nil] seconds, nil when no merge of the branch or no commit is found
        def call(key)
          merge = merge_of(key)
          first = merge && first_commit(merge)
          first && [Time.iso8601(merge[1]) - Time.iso8601(first), 0].max.to_i
        end

        private

        def merge_of(key)
          out = run("log", "main", "--merges", "-1", "--format=%H %cI", "--fixed-strings", "--grep=#{key}")
          out.split.then { |parts| parts if parts.size == 2 }
        end

        def first_commit(merge)
          run("log", "--reverse", "--format=%aI", "#{merge[0]}^1..#{merge[0]}^2").lines.first&.strip
        end

        def run(*)
          result = @git.capture(*, chdir: @checkout)
          result.ok? ? result.out : ""
        end
      end
    end
  end
end
