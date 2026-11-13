# frozen_string_literal: true

require "time"
require_relative "../shell"

module Hecks
  module Adapters
    class Dispatching
      # Whether a started work item's branch landed since the work item started: the commit of one
      # of its landings that was made at or after its start. A landing of an earlier start of a
      # reopened work item is older than the new start, so it does not count.
      #
      # A commit is made during the session that lands it, and a rebase onto main only makes it
      # later, so the commit's committer time is the landing's time as far as the start is
      # concerned. A work item that records no start, or a commit whose time cannot be read,
      # counts as not landed, and the settle yields it as it would with no landing.
      class LandedSince
        # @param work_items [WorkItems] answers `landed_commits` and `claimed_at` for a key
        # @param repo [String, nil] the checkout whose repository holds the landed commits
        # @param committed_at [#call, nil] answers a commit's committer time as text, nil when it
        #   cannot be read; reads the repository in `repo` when none is given
        def initialize(work_items, repo: nil, committed_at: nil)
          @work_items = work_items
          @committed_at = committed_at || ->(sha) { self.class.committer_time(repo, sha) }
        end

        # @param repo [String, nil] the checkout to read in
        # @param sha [String] the commit
        # @return [String, nil] its committer time, nil when the repository cannot say
        def self.committer_time(repo, sha)
          answer = Shell.new.capture("git", "show", "-s", "--format=%cI", sha, chdir: repo)
          answer.ok? ? answer.out.strip : nil
        rescue SystemCallError
          nil
        end

        # @param key [String] the started work item
        # @return [String, nil] the commit its branch landed as since it started, nil when none did
        def call(key)
          started = time(@work_items.claimed_at(key))
          return unless started

          @work_items.landed_commits(key).find { |sha| since?(sha, started) }
        end

        private

        def since?(sha, started)
          made = time(@committed_at.call(sha))
          !made.nil? && made >= started
        end

        def time(text)
          text.to_s.empty? ? nil : Time.iso8601(text.to_s)
        rescue ArgumentError
          nil
        end
      end
    end
  end
end
