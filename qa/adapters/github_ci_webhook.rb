# frozen_string_literal: true

# THE PUSH SIBLING OF `qa/adapters/github_checks.rb`. That file is what
# `Clearance.CI.Run` (the `CI` port's own `asks "Run"`) calls when
# `bin/qa_pr_check` POLLS — it shells to `gh api .../check-runs`, once
# per PR, once per run of that script. This is the other half of "notice
# it and act": GitHub calling IN, the moment a run actually finishes,
# instead of this repository calling OUT and hoping it asked at the
# right moment. Same ledger, same eventual record
# (`QualityControl::Clearance`), a different trigger.
#
# WHY `check_suite`, NOT `workflow_run` OR `check_run` — investigated,
# not assumed, against what GitHub's webhook payloads actually carry:
#
#   * `check_run` fires per INDIVIDUAL check (one job) and its own
#     `conclusion` answers for that job alone — exactly the granularity
#     `GithubChecks#run` already has to look PAST, by asking for every
#     check-run against a commit and requiring all of them green. A
#     webhook driven off `check_run` would need to re-implement that
#     same aggregation itself, against a stream of separate deliveries
#     arriving in no particular order — the one thing this file exists
#     to avoid restating.
#
#   * `workflow_run` fires per Actions WORKFLOW FILE completing. A repo
#     with more than one workflow file (this one has several) mints one
#     `workflow_run` delivery PER FILE, per commit — so "did the whole
#     CI run for this commit pass" would still need combining more than
#     one delivery, the exact aggregation problem above, just moved up
#     one level.
#
#   * `check_suite` is GitHub's OWN aggregate, computed server-side,
#     across every check run posted against one commit by one App — and
#     GitHub Actions posts every job from every workflow file as check
#     runs under the SAME App, so one `check_suite` covers a commit's
#     entire CI picture the identical way `GithubChecks#run`'s own
#     "every check-run against this sha" already does. Its `conclusion`
#     is null until every check run inside it has settled, and reflects
#     ALL of them once it does — precisely "did the whole CI run for
#     this commit pass or fail," delivered once, needing nothing
#     combined here.
#
# `action: "completed"` IS THE ONLY ACTION THIS HANDLES. GitHub also
# sends `check_suite` events for `"requested"`/`"rerequested"` — the
# suite EXISTS but has not finished — and answering those would be
# exactly the failure `GithubChecks`'s own header already refuses under
# "PENDING STAYS OUTSIDE THE PORT": there is no `Clearance` ending that
# means "still running," so a run that has not finished is acknowledged
# and otherwise ignored, never turned into a verdict.
require_relative "../../lib/hecks/adapters/driving/github_webhook"
require_relative "clearance_recorder"

module Hecks
  module Adapters
    module Driving
      # The QA ledger's own driving adapter — GitHub's `check_suite`
      # webhook, verified and unwrapped by the generic base class,
      # turned into a `QualityControl::Clearance`. See this file's own
      # header for why `check_suite` and not `workflow_run`/`check_run`.
      class GithubCiWebhook < GithubWebhook
        SHA_PATTERN = /\A[0-9a-fA-F]{7,40}\z/

        def handle_event(event, action, payload)
          return ignored("not a check_suite event (got #{event.inspect})") unless event == "check_suite"
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

        # THE ACTUAL RECORD — `ClearanceRecorder.record` is the exact
        # same "start it, then settle it" step `bin/qa_pr_check` now
        # calls too (`ensure_started`), so this file never re-derives
        # what counts as green or re-implements how a `Clearance` gets
        # minted. All this method does that is genuinely its own: read
        # GitHub's own verdict out of an already-verified payload.
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
