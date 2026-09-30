# frozen_string_literal: true

require_relative "../../adapters/driving/github_webhook"
require_relative "clearance_recorder"

module Hecks
  module Adapters
    module Driving
      # Records GitHub's `check_suite` webhook as a `QualityControl::Clearance`.
      # GitHub sends one `check_suite` per GitHub App for a commit, so one suite is not the
      # commit's verdict. A passing suite clears the commit only when it belongs to `CI_APP_SLUG`
      # (Actions, which runs the gate); a passing suite from any other app is acknowledged and
      # ignored. A failing suite from any app holds the commit red, and the first verdict stands.
      class GithubCiWebhook < GithubWebhook
        SHA_PATTERN = /\A[0-9a-fA-F]{7,40}\z/

        # The GitHub App whose passing suite counts as the commit being green.
        CI_APP_SLUG = "github-actions"

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
          app        = suite.dig("app", "slug").to_s
          if passed && app != CI_APP_SLUG
            return ignored("passing check_suite from app #{app.inspect}, not #{CI_APP_SLUG.inspect}")
          end

          summary = "check_suite #{suite['id']} conclusion=#{conclusion} for #{sha[0, 7]} — via webhook"

          cleared = Hecks::QA::ClearanceRecorder.record(commit: sha, passed: passed, summary: summary)

          [200, { ok: true, commit: sha, status: cleared.status, summary: summary }]
        end
      end
    end
  end
end
