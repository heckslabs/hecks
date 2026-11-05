# Main moves by pull request, and the candidate gate is retired

**Status:** Accepted, shipped. Date: 2026-11-05. Supersedes ADR 0181. Owner decision:
"we are using prs now not pushing to main". Shipped as #1201 (the train boards main as a pull
request) and #1207 (the candidate domain removed).

## Context

ADR 0181 kept `main` off untested heads by queuing every boarding as a candidate ref, letting CI
judge it there, and fast-forwarding `main` only onto a green candidate. It worked, but it was a
second gate beside the one GitHub already runs on a pull request, and it needed its own domain
(`Candidate`), its own workflow (`candidate.yml`), a hook rule, a CI-run branch, and a red-candidate
path. The owner moved the team to pull requests, so `main` is now changed only by a merge that
GitHub makes after the required checks pass.

## Decision

1. **Boarding opens a pull request.** `SendTrain.board!` pushes the boarded commit to its own
   branch, `train/main-<sha>`, opens a PR into `main` with `gh pr create`, and turns on auto-merge
   with `gh pr merge --auto`. The train never moves `main` itself. The outcome is `queued`.
   Implemented by `PullRequestBoarding` (`lib/hecks/hecks/adapters/git_train/pull_request_boarding.rb`).
2. **A merge records the push.** `SendTrain.Watch` reads each queued boarding's PR. Once merged,
   the merge commit is the pushed commit (`SendTrain.Merge`), which fires the existing
   `BranchPushed` policies: the launcher refresh and the deploy announcement. An open PR changes
   nothing.
3. **The QA tick does the watching.** The tick's train watch step runs `Watch` on every queued
   boarding, so a merge is recorded without a person. The train and the tick share one SQLite file
   (a gitignored local config; see `hecks.local.hecksagon` in each checkout).
4. **The candidate gate is removed.** The `Candidate` bluebook, its `Gating` port, the world's
   `gate` row, the `candidate_gating` adapters, `CandidateBoarding`, the candidate marker and
   green-tree helpers, the CI-run candidate branch, the candidate-run policies, `candidate.yml`, the
   trigger and projection entries for it, and the pre-push rule that held `main` to promotion are
   all gone.

## Consequences

- `main` has no pushed-to-main path except a merge. The pre-push hook still refuses a plain push of
  `main`; the train's own push is the one that carries the `hecks.trainCarry` marker, and the merge is
  GitHub's.
- A boarding waits for CI on its PR rather than on a candidate ref, so the red-flag path for
  candidates is gone. A red PR stays open and is read as a failed check.
- A merge is recorded only while the QA tick runs. A boarding whose PR merged while the tick is not
  running stays queued until the next tick; `Queued` lists them.
- The train's queued state lives in a per-machine SQLite file, configured in gitignored local files,
  so a fresh checkout records nothing until it is configured.

## Open

- `CLAUDE.md` still says not to open a pull request for `main`; that predates this decision.
- The repository's merge queue sets the merge strategy, so auto-merge is enabled without `--squash`.
