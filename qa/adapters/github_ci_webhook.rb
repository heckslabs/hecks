# frozen_string_literal: true

require_relative "../../lib/hecks/adapters/driving/github_webhook"
require_relative "clearance_recorder"

module Hecks
  module Adapters
    module Driving
      # Records GitHub's `check_suite` webhook as a `QualityControl::Clearance`.
      # `check_suite` is GitHub's own aggregate over a commit's check runs, so none need combining.
      class GithubCiWebhook < GithubWebhook
        SHA_PATTERN = /\A[0-9a-fA-F]{7,40}\z/

        def handle_event(event, action, payload)
          return ignored("not a check_suite event (got #{event.inspect})") unless event == "check_suite"
          # `requested`/`rerequested` mean the suite has not finished, so there is no verdict yet.
          return ignored("check_suite not yet completed (action=#{action.inspect})") unless action == "completed"

          suite = payload["check_suite"] || {}
          sha   = suite["head_sha"].to_s

          unless sha.match?(SHA_PATTERN)
            return [422, { error: "MalformedCommit", message: "check_suite.head_sha #{sha.inspect} does not look like a sha" }]
          end

          settle(sha, suite)
        end

        private

        def ignored(reason) = [200, { ok: true, ignored: reason }]

        def settle(sha, suite)
          conclusion = suite["conclusion"].to_s
          passed     = Hecks::QA::ClearanceRecorder::PASSING.include?(conclusion)
          summary    = "check_suite #{suite['id']} conclusion=#{conclusion} for #{sha[0, 7]} — via webhook"

          cleared = Hecks::QA::ClearanceRecorder.record(commit: sha, passed: passed, summary: summary)

          [200, { ok: true, commit: sha, status: cleared.status, summary: summary }]
        end
      end
    end
  end
end
