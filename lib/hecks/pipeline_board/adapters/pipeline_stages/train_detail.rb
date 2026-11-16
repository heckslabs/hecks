# frozen_string_literal: true

require "json"
require_relative "../probe"
require_relative "../../../hecks/adapters/started_work"
require_relative "../../../hecks/adapters/gh_rest"

module Hecks
  module Adapters
    module PipelineBoard
      # What one `/trains/<run>` page shows: how a SendTrain boarding ended, from the launcher's
      # `SendTrain.outcome`, and the pull request that carried it, from `gh api`. It only reads.
      class TrainDetail
        FIELDS = %w[status branch boarded pushed commits report refusal].freeze

        # @param root [String] the checkout `gh` runs in
        # @param live_store [LiveStore, nil] the store the boardings are read from, in this process
        # @param outcome [#call, nil] takes the run key and answers the outcome rows
        # @param pull_request [#call, nil] takes the PR branch and answers `gh`'s parsed JSON
        def initialize(root:, live_store: nil, outcome: nil, pull_request: nil)
          @outcome = outcome || ->(key) { boardings(live_store, key) }
          @pull_request = pull_request || rest_pull_request(root)
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

        # The pull request of a branch read over REST, whose budget is apart from GraphQL's.
        def rest_pull_request(root)
          rest = Hecks::Adapters::GhRest.new(->(*args) { Probe.json("gh", *args, chdir: root) })
          ->(branch) { rest.pull(branch) }
        end

        # The SendTrain records of the key, as the rows `SendTrain.outcome` answers.
        def boardings(live_store, key)
          raise Unavailable, "no live store to read the boarding from" unless live_store

          live_store.records("Hecks", "SendTrain").filter_map do |record|
            next unless StartedWork.value(record, :run).to_s == key

            (FIELDS - ["status"]).to_h { |name| [name, StartedWork.value(record, name.to_sym)] }
                                 .merge("status" => StartedWork.value(record, :status))
          end
        end

        def outcome_of(detail)
          detail[:refusal].empty? ? detail[:status] : "#{detail[:status]}: #{detail[:refusal]}"
        end

        def pr_of(detail)
          return if detail[:boarded].empty?

          view = @pull_request.call("train/main-#{detail[:boarded][0, 12]}")
          return unless view

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
