# frozen_string_literal: true

require "hecks/pipeline_board/adapters/probe"

module Hecks
  module Adapters
    # The `Host` port's adapter for GitHub: answers `PullRequest`'s `Lookup` from the pull request
    # `gh` reports.
    class PullRequestHost
      FIELDS = "number,title,state,isDraft,mergeStateStatus,headRefName"

      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] the checkout `gh` runs in; the current directory when nil
      def initialize(aggregate: nil, settings: {}, root: nil)
        @root = root || Dir.pwd
      end

      # @param number [Hash, Integer, String] the pull request's number
      # @return [Hash] `text:` the pull request as JSON
      def lookup(number:)
        value = number.is_a?(Hash) ? (number[:value] || number["value"]) : number
        { text: PipelineBoard::Probe.run("gh", "pr", "view", value.to_s, "--json", FIELDS, chdir: @root) }
      end
    end
  end
end
