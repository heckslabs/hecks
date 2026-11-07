# frozen_string_literal: true

require_relative "../../../check_conclusion"

module Hecks
  module Adapters
    module PipelineBoard
      # The open train pull requests and how their checks stand, read from `gh pr list`. A train
      # pull request is one on a `train/` branch.
      module PullChecks
        BRANCH_PREFIX = "train/"
        FIELDS = "number,headRefName,statusCheckRollup"
        WAITING = %w[pending expected queued in_progress waiting requested].freeze

        module_function

        # @param listed [Array<Hash>] `gh pr list --json` rows
        # @return [Array<Hash>] `number`, `branch`, `passed`, `failed`, `pending` and `total` for each
        #   open pull request on a train branch
        def train(listed)
          trains = Array(listed).select { |pull| pull["headRefName"].to_s.start_with?(BRANCH_PREFIX) }
          trains.map { |pull| counted(pull) }
        end

        # @return [Hash] one pull request with its checks counted by how they stand
        def counted(pull)
          stands = Array(pull["statusCheckRollup"]).map { |check| standing(check) }
          tally = stands.tally
          { number: pull["number"], branch: pull["headRefName"], total: stands.size,
            passed: tally.fetch(:passed, 0), failed: tally.fetch(:failed, 0), pending: tally.fetch(:pending, 0) }
        end

        # @param check [Hash] a check run or a status context, as `statusCheckRollup` lists it
        # @return [Symbol] `:passed`, `:failed` or `:pending`
        def standing(check)
          word = (check["conclusion"].to_s.empty? ? check["state"] : check["conclusion"]).to_s.downcase
          return :pending if word.empty? || WAITING.include?(word)

          Hecks::CheckConclusion.certifies?(word) || Hecks::CheckConclusion.clean?(word) ? :passed : :failed
        end
      end
    end
  end
end
