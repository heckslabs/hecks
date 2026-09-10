# frozen_string_literal: true

require "open3"
require "json"

module Hecks
  module Adapters
    # THE "CI" PORT, FOR REAL — what `Clearance.CI.Run` (`quality_control.
    # hecksagon`'s own `asks "Run"`) actually calls out to. Everything
    # `bin/qa_pr_check` used to do by hand — shell to `gh`, read what came
    # back, decide green or red — lives here now, behind the boundary the
    # port already drew: this class answers or refuses, and the two
    # policies at the foot of `quality_control.bluebook` (`ClearOnPass`,
    # `RefuseOnFail`) are what turn that into `Clearance::Passed`/`Failed`.
    # The script's own job shrinks to "which commit is worth asking about
    # at all" — see `bin/qa_pr_check`'s own header for why that split holds.
    #
    # BY COMMIT, NOT BY PR NUMBER — deliberately not `gh pr checks <n>`,
    # even though that is what a first draft of this reused wholesale.
    # `Clearance` is `identified_by :commit` and nothing else (see its own
    # header: "a clearance is minted per commit"), and GitHub's own Checks
    # API answers the identical question keyed the same way —
    # `repos/{owner}/{repo}/commits/{sha}/check-runs` — with no PR lookup
    # in between. Confirmed live against this repository's own merged
    # history before writing a line of the caller (`gh api
    # repos/{owner}/{repo}/commits/<merged PR's own head sha>/check-runs`
    # returned the identical thirteen checks `gh pr checks <n>` did for the
    # same commit). Asking by commit also keeps answering "is THIS sha
    # clean" possible even once the branch that carried it is gone —
    # `gh pr checks` has nothing left to ask by then; the commit's own
    # history on GitHub still does.
    #
    # `{owner}/{repo}` IS A REAL `gh api` TEMPLATE, not a placeholder this
    # class fills in — `gh` resolves it from the repository the current
    # working directory's own git remote names, the same inference `gh pr
    # list`/`gh pr checks` already lean on everywhere else in this ledger's
    # own tooling. Confirmed live, not assumed.
    class GithubChecks
      # `aggregate:`/`settings:`/`root:` — the same three keywords every
      # driven adapter's own `initialize` accepts (`MockStripeAdapter`'s
      # own comment), all unused here: this adapter takes no per-boot
      # configuration of its own, only the commit each `Run` names.
      def initialize(aggregate: nil, settings: {}, root: nil); end

      # A CHECK RUN'S "conclusion" THAT COUNTS AS GREEN. `success` is the
      # obvious one; `neutral`/`skipped` are GitHub's own words for "ran,
      # and chose not to fail the commit" — a workflow gated on a path
      # filter that did not match this commit is `skipped`, not evidence
      # against it. Everything else (`failure`, `cancelled`, `timed_out`,
      # `action_required`, `stale`, or no conclusion at all) counts against.
      PASSING = %w[success neutral skipped].freeze

      # `commit:` ARRIVES AS THE WHOLE VALUE OBJECT'S OWN SHAPE
      # (`{value: "4f2a19c"}`) — `PortOperationInterpreter#ask` hands an
      # adapter `Value.materialize`d state and args, never a bare Ruby
      # value (see that method's own comment: "a Value never crosses the
      # boundary — an adapter is somebody else's code and should be
      # handed plain data"). `summary` — the record's OWN state at ask
      # time, unset while `Clearance` is still `"running"` — arrives the
      # same way and is simply ignored; this adapter answers from what
      # GitHub says now, never from what the record already held.
      def run(commit:, **)
        sha = sha_of(commit)
        runs = check_runs(sha)

        raise "gh reports no checks at all against #{sha}" if runs.empty?

        # DEFENSIVE, NOT EXPECTED. `bin/qa_pr_check` only ever dispatches
        # `Run` once ITS OWN `gh pr checks` has already shown nothing
        # pending — reaching here mid-flight would mean a check started
        # running in the handful of seconds between that look and this
        # one. Answering `SuitePassed` on an incomplete run would be
        # exactly the quiet-divergence failure this whole ledger exists
        # to hunt, so this refuses instead — a false red one script tick
        # can fix by asking again once the run actually finishes,
        # against a fresh, still-unminted commit if a push follows, or
        # left for a human to read `Clearance.Red` if it does not.
        incomplete = runs.reject { |run| run["status"] == "completed" }
        raise "checks against #{sha} are still running — asked before they settled" if incomplete.any?

        failing = runs.reject { |run| PASSING.include?(run["conclusion"]) }
        return { summary: { value: "#{runs.length} checks, all green (#{sha[0, 7]})" } } if failing.empty?

        raise "#{failing.length} of #{runs.length} checks failed against #{sha[0, 7]}: " \
              "#{failing.map { |run| run['name'] }.join(', ')}"
      end

      private

      # THE SAME SHAPE `commit:` CAN ARRIVE IN, tolerated rather than
      # assumed — a value object's own materialized hash (`{value: "…"}`,
      # the live shape), symbol or string keyed depending on the caller
      # (`Value.materialize` always gives symbol keys; a hand-built Hash
      # calling this directly, the way this class's own spec does to
      # avoid a real `gh` call, might not), or a bare string for a caller
      # that already unwrapped it.
      def sha_of(commit)
        return commit if commit.is_a?(String)

        (commit.key?(:value) ? commit[:value] : commit["value"]).to_s
      end

      # ONE SHELL CALL, ITS OWN EXIT CODE READ — same discipline
      # `bin/qa_pr_check`'s own `gh(*)` helper already established: `gh`'s
      # exit code answers only "did the call itself succeed," never "what
      # did GitHub say," which is what the parsed body is for.
      def check_runs(sha)
        out, err, status = Open3.capture3("gh", "api", "repos/{owner}/{repo}/commits/#{sha}/check-runs")
        raise "gh api check-runs failed for #{sha}: #{err.strip.empty? ? out.strip : err.strip}" unless status.success?

        JSON.parse(out)["check_runs"] || []
      end
    end
  end
end
