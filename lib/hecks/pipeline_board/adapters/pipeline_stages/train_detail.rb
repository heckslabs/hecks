# frozen_string_literal: true

require "json"
require_relative "../probe"

module Hecks
  module Adapters
    module PipelineBoard
      # What one `/trains/<run>` page shows: how a SendTrain boarding ended, from the launcher's
      # `SendTrain.outcome`, and the pull request that carried it, from `gh pr view`. It only reads.
      class TrainDetail
        FIELDS = %w[status branch boarded pushed commits report refusal].freeze
        PR_FIELDS = "number,url,state,mergeCommit,statusCheckRollup"

        # @param root [String] the checkout whose launcher holds the live store
        # @param outcome [#call, nil] takes the run key and answers the outcome rows
        # @param pull_request [#call, nil] takes the PR branch and answers `gh`'s parsed JSON
        def initialize(root:, outcome: nil, pull_request: nil)
          @outcome = outcome || ->(key) { Probe.json("exe/hecks", "SendTrain.outcome", "run.value=#{key}", chdir: root) }
          @pull_request = pull_request || ->(branch) { Probe.json("gh", "pr", "view", branch, "--json", PR_FIELDS, chdir: root) }
        end

        # @param key [String] a SendTrain run key
        # @return [Hash, nil] the boarding's `run`, `status`, `boarded`, `pushed`, `commits`,
        #   `report`, `refusal`, `outcome` and its `pr` (`number`, `url`, `state`, `checks`);
        #   nil when none has that key
        def of(key)
          row = Array(@outcome.call(key)).first
          return unless row

          detail = FIELDS.to_h { |name| [name.to_sym, row[name].to_s] }.merge(run: key)
          detail.merge(outcome: outcome_of(detail), pr: pr_of(detail))
        end

        private

        def outcome_of(detail)
          detail[:refusal].empty? ? detail[:status] : "#{detail[:status]}: #{detail[:refusal]}"
        end

        def pr_of(detail)
          return if detail[:boarded].empty?

          view = @pull_request.call("train/main-#{detail[:boarded][0, 12]}")
          { number: view["number"], url: view["url"], state: view["state"].to_s.downcase, merge: view.dig("mergeCommit", "oid"),
            checks: Array(view["statusCheckRollup"]).map { |check| check_of(check) } }
        rescue PipelineBoard::Unavailable
          nil
        end

        def check_of(check)
          { name: first_of(check, "name", "context"), result: first_of(check, "conclusion", "state", "status"),
            url: first_of(check, "detailsUrl", "targetUrl") }
        end

        # The value of the first of `keys` the check holds with some text, else an empty string.
        def first_of(check, *keys)
          keys.map { |key| check[key].to_s }.find { |text| !text.empty? }.to_s
        end
      end
    end
  end
end
