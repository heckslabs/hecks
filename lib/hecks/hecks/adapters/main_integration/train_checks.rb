# frozen_string_literal: true

require_relative "../ci_runs"
require_relative "../ci_runs/pull_request"

module Hecks
  module Adapters
    class MainIntegration
      # Which pushed or watched run holds the line, judged from its train pull request's checks.
      # A run whose open pull request has a failed check and no check left running will not merge,
      # so it does not hold the line: the next verified landing boards and its pull request
      # replaces it. A pull request that cannot be read leaves its run holding the line. Reads
      # GitHub only.
      class TrainChecks
        # The stages whose runs have a train pull request to read.
        WATCHED = %w[pushed ci_running].freeze

        # @param runner [#call, nil] takes `(argv, chdir:)` and answers `[ok, output]`; the one
        #   `CiRuns` reads GitHub with when nil
        def initialize(runner = nil)
          @runner = runner || CiRuns.runner || CommandRunner.new
        end

        # @param others [Array<Runs::Run>] the runs in flight besides the one to board
        # @return [Array(Runs::Run, CiRuns::Checks), nil] the first run still holding the line, with
        #   its checks when they could be read
        def blocking(others)
          others.each do |run|
            checks = checks_of(run)
            return [run, checks] unless checks&.failed_and_complete?
          end
          nil
        end

        private

        def checks_of(run)
          return nil unless WATCHED.include?(run.state)

          CiRuns::PullRequest.new(@runner, run.checkout.empty? ? Dir.pwd : run.checkout, run.landed).checks
        rescue StandardError
          nil
        end
      end
    end
  end
end
