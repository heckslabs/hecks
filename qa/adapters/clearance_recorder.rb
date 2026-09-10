# frozen_string_literal: true

# "RECORD WHAT CI SAID FOR THIS COMMIT" — currently the PUSH trigger's
# own step (`qa/adapters/github_ci_webhook.rb`: GitHub already tells it
# pass or fail, verified, no polling needed), kept as its own module
# rather than inlined so the idempotency this route genuinely needs
# (below) isn't buried inside a Rack handler.
#
# NOT SHARED WITH `bin/qa_pr_check` ANY MORE. The PULL trigger used to
# call `ensure_started` too, before `bin/qa_pr_check` was rewritten
# (`qa: track opened PRs as a first-class Patch aggregate...`, #539) to
# settle through the real `CI` port instead: `Clearance.start!` directly,
# then `Clearance.CI.Run` — the chapter's own `ClearOnPass`/`RefuseOnFail`
# policies turn that port's answer or refusal into
# `Clearance::Passed`/`Failed` automatically (see that script's own
# header on why that indirection has to stay live rather than being
# shortcut around). That rewrite landed independently of this file and
# never mentions it — see `Patch`'s own comment in
# `qa/bluebook/quality_control.bluebook` for what #539 actually changed.
# `bin/qa_pr_check`'s own `ask_the_ledger` only reaches `Clearance.start!`
# once it has already confirmed (via `Patch.Open` + `Clearance.All`) that
# no `Clearance` exists yet for that commit, so it doesn't need this
# module's `AlreadyExists`-swallowing guard the same way the push route
# does — though a poll racing a webhook redelivery for the same
# still-unsettled commit is a real, un-guarded corner case this file does
# not close.
#
# `Start` (NOT `Passed`/`Failed`) IS STILL THE PART EITHER ROUTE WOULD
# SHARE, if `bin/qa_pr_check` used this module again. The push route has
# no port to ask — GitHub already handed it a verified verdict, so
# re-asking `gh` would just throw away the whole point of a webhook — so
# it settles directly, through the same `Clearance::Passed`/
# `Clearance::Failed` commands `ClearOnPass`/`RefuseOnFail` dispatch on
# the pull route's behalf. Either way, the record that lands in the
# ledger is identical; only how each route LEARNS the verdict differs.

module Hecks
  module QA
    # Records what CI said about one commit — currently the PUSH
    # trigger's own step; see this file's own header for why the PULL
    # trigger (`bin/qa_pr_check`) does not call this module any more.
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
