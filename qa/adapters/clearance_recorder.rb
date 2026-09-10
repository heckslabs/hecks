# frozen_string_literal: true

# THE ONE STEP BOTH TRIGGERS SHARE — "record what CI said for this
# commit." `bin/qa_pr_check` (the PULL trigger: it polls, then asks the
# `CI` port, and the chapter's own `ClearOnPass`/`RefuseOnFail` policies
# turn the port's answer or refusal into `Clearance::Passed`/`Failed`
# automatically) and `qa/adapters/github_ci_webhook.rb` (the PUSH
# trigger: GitHub already tells it pass or fail, verified, no polling
# needed) used to each mint a `Clearance` their own way — this is the one
# place that logic lives now, so neither has to restate "start it, then
# settle it, and do not blow up if it is already settled."
#
# `Start` (NOT `Passed`/`Failed`) IS THE PART BOTH ROUTES ACTUALLY NEED
# SHARED. The pull route still turns its verdict into `Passed`/`Failed`
# through the real `CI` port + policies — see `bin/qa_pr_check`'s own
# header on why that indirection has to stay live rather than being
# shortcut around a second time (`ClearOnPass`/`RefuseOnFail` going dead
# is the exact regression that script's own header already warns about).
# The push route has no port to ask — GitHub already handed it a
# verified verdict, so re-asking `gh` would just throw away the whole
# point of a webhook — so it settles directly, through the same
# `Clearance::Passed`/`Clearance::Failed` commands the policies dispatch
# on the pull route's behalf. Either way, the record that lands in the
# ledger is identical; only how each route LEARNS the verdict differs.

module Hecks
  module QA
    # Records what CI said about one commit, shared by the pull and push
    # triggers alike — see this file's own header for the full reasoning.
    module ClearanceRecorder
      module_function

      # A CONCLUSION THAT COUNTS AS GREEN — the same three words
      # `Hecks::Adapters::GithubChecks::PASSING` already classifies
      # per-check-run: `success` outright, `neutral`/`skipped` because
      # GitHub uses those for "ran, and chose not to fail the commit."
      # Kept here rather than read off that class because a `check_suite`
      # payload's own `conclusion` is GitHub's OWN aggregate across every
      # check run in the suite (see `github_ci_webhook.rb`'s own header
      # for why `check_suite` was chosen), not a single run — the same
      # closed vocabulary applies to both, so the constant is shared
      # rather than each side keeping its own copy to drift.
      PASSING = %w[success neutral skipped].freeze

      # IDEMPOTENT — a webhook redelivers (GitHub's own retry policy),
      # and a poll can race a push for the same commit. `Clearance.Start`
      # is a CREATING command (`identified_by :commit`), so a second call
      # for the same sha refuses with `AlreadyExists`; that refusal is
      # exactly "somebody already started this," not a real problem, so
      # it is swallowed here rather than propagated — the caller gets the
      # existing record back either way.
      def ensure_started(commit)
        QualityControl::Clearance.find(commit) ||
          QualityControl::Clearance.start!(commit: { value: commit })
      rescue Hecks::Runtime::AlreadyExists
        QualityControl::Clearance.find(commit)
      end

      # THE FULL RECORD, START TO SETTLED — used by the PUSH trigger only
      # (see this file's own header for why the pull trigger settles
      # through the port instead). Idempotent the same way
      # `ensure_started` is: a commit already settled (green OR red,
      # `Clearance`'s own header: "nothing has to make it stale") is left
      # exactly as it is — a webhook redelivering the SAME verdict twice
      # must not raise `LifecycleRefused` trying to move an already-
      # settled record a second time, and a webhook somehow disagreeing
      # with an already-settled verdict is not this method's call to
      # arbitrate; the FIRST verdict recorded for a commit is the one
      # that stands; see `Clearance`'s own header once more.
      #
      # Returns the settled Clearance record either way.
      def record(commit:, passed:, summary:)
        cleared = ensure_started(commit)
        return cleared if cleared.status != "running"

        passed ? cleared.passed!(summary: { value: summary }) : cleared.failed!(refusal: { value: summary })
      end
    end
  end
end
