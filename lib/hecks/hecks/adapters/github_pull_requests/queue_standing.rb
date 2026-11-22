# frozen_string_literal: true

require "json"

module Hecks
  module Adapters
    class GithubPullRequests
      # Where one pull request stands in GitHub's merge queue: queued, merging, merged, dropped or
      # not queued. `gh pr view --json` has no merge queue field, so everything comes from one
      # GraphQL read: the entry, the merge time, and the latest add to or removal from the queue.
      # This is the one home of the rule that turns GitHub's facts into a place.
      class QueueStanding
        QUERY = <<~GRAPHQL
          query($owner: String!, $name: String!, $number: Int!) {
            repository(owner: $owner, name: $name) {
              pullRequest(number: $number) {
                mergedAt
                mergeQueueEntry { state position }
                timelineItems(last: 1, itemTypes: [ADDED_TO_MERGE_QUEUE_EVENT, REMOVED_FROM_MERGE_QUEUE_EVENT]) {
                  nodes { __typename }
                }
              }
            }
          }
        GRAPHQL

        # @param github [#call] runs `gh` with its arguments and returns stdout, raising on failure
        def initialize(github)
          @github = github
        end

        # @param number [String] the pull request number
        # @return [String] `queued`, `merging` (each with its position), `merged`, `dropped` or
        #   `not queued`
        def place(number)
          pull = read(number)
          return "merged" if pull["mergedAt"]
          return entry_place(pull["mergeQueueEntry"]) if pull["mergeQueueEntry"]

          removed_last?(pull) ? "dropped" : "not queued"
        end

        private

        def entry_place(entry)
          word = %w[MERGEABLE LOCKED].include?(entry["state"]) ? "merging" : "queued"
          entry["position"] ? "#{word} (position #{entry["position"]})" : word
        end

        def removed_last?(pull)
          pull.dig("timelineItems", "nodes").to_a.last&.dig("__typename") == "RemovedFromMergeQueueEvent"
        end

        def read(number)
          out = @github.call("api", "graphql", "-F", "owner={owner}", "-F", "name={repo}",
                             "-F", "number=#{number}", "-f", "query=#{QUERY}")
          JSON.parse(out).dig("data", "repository", "pullRequest") || {}
        end
      end
    end
  end
end
