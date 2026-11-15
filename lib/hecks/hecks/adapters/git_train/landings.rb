# frozen_string_literal: true

require_relative "reading"

module Hecks
  module Adapters
    class GitTrain
      # The landings a boarded commit carries beyond the remote's branch, read as facts: each is a
      # first-parent merge commit with the paths it changed. It decides nothing; whether a red
      # check belongs to one of them is the domain's rule.
      class Landings
        include Reading

        # @param git [Git] the adapter every git call goes through
        # @param checkout [String] the repository's top level
        def initialize(git, checkout)
          @git = git
          @checkout = checkout
        end

        # @param boarded [String] the commit the boarding carries
        # @param base [String] the ref the remote's branch is read at (`origin/main`)
        # @return [Array<Hash{Symbol => Object}>] oldest first: `sha:`, `subject:` and `paths:`
        def list(boarded, base)
          read("rev-list", "--first-parent", "--merges", "--reverse", "#{base}..#{boarded}").lines.map do |line|
            sha = line.strip
            { sha: sha, subject: read("log", "-1", "--format=%s", sha), paths: paths(sha) }
          end
        end

        private

        # The paths a landing changed against its first parent.
        def paths(sha) = read("diff", "--name-only", "#{sha}^1", sha).lines.map(&:strip)
      end
    end
  end
end
