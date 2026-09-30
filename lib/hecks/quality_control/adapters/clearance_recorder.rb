# frozen_string_literal: true

module Hecks
  module QA
    # Records what CI said about one commit as a `QualityControl::Clearance`.
    module ClearanceRecorder
      module_function

      # Conclusions that count as green; same vocabulary as `GithubChecks::PASSING`.
      # A `check_suite` conclusion aggregates one GitHub App's runs only, so callers decide
      # which suites may pass a commit.
      PASSING = %w[success neutral skipped].freeze

      # Returns the Clearance for `commit`, starting one if none exists.
      # `AlreadyExists` from a redelivered webhook racing another start is swallowed.
      def ensure_started(commit)
        QualityControl::Clearance.find(commit) ||
          QualityControl::Clearance.start!(commit: { value: commit })
      rescue Hecks::Runtime::AlreadyExists
        QualityControl::Clearance.find(commit)
      end

      # Starts and settles the Clearance for `commit`; the first verdict recorded stands.
      # An already-settled record is returned unchanged, so redelivery cannot raise
      # `LifecycleRefused`.
      #
      # @return the settled Clearance
      def record(commit:, passed:, summary:)
        cleared = ensure_started(commit)
        return cleared if cleared.status != "running"

        passed ? cleared.passed!(summary: { value: summary }) : cleared.failed!(refusal: { value: summary })
      end
    end
  end
end
