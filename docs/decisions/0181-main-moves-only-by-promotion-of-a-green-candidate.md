# Main moves only by promotion of a green candidate

**Status:** Accepted, shipped off. Date: 2026-11-03. Owner decision after the reds of
2026-11-02 and 2026-11-03: "this isn't working then" and "yes dispatch the gate". Work item
`candidate-gate`.

## Context

On those two days nearly every red run of `main` was an untested combination reaching it:
three coders boarding at once, a session boarding with no pusher assigned, two heads stacked
on a red one, and local checks that missed what only CI runs (a shallow clone, the fuzz legs,
the shards). The red flag, the kick and the restore kept `main` recoverable, not green, and
twelve revert and restore commits in five hours cost more than the failures they undid.

The push train is the one path to `main` (`SendTrain.board!`, `lib/hecks/hecks/adapters/
git_train.rb`), the pre-push hook refuses a push of `main` the train does not carry, CI runs on
`pull_request` and on a push to `main`, Promote moves `stable` onto the newest commit every
required check passed on, and Release runs after Promote. The coordinator session is the only
pusher.

## Decision

`main` is gated by a candidate. While the gate is on:

1. **Boarding queues a candidate.** `SendTrain.board!` pushes local `main`'s tip to
   `refs/heads/candidate`, not to `main`, and records it in the repository's git directory
   (`hecks-candidate.json`: the sha, the base it was built on, the commits it carries, its CI
   run once known, and its state). The outcome is `queued` (`SendTrain.BoardingQueued`). One
   candidate is in flight at a time: a boarding while one is queued, green or red is refused by
   name (`candidate <sha> is in flight: run <id>`). Refusing, not waiting, was chosen because a
   boarding that waited would push a head built on a candidate not yet judged, which is the
   stacking the gate exists to stop; the coordinator boards again once the candidate settles.
2. **The tree-match rule stands.** A boarded commit whose tree equals the tree of a commit CI
   already passed on (a green push of `main` or of `candidate`, read through `gh`) is promoted
   at once: pushed to `main` as a promotion, with no run of its own.
3. **CI runs on the candidate.** `ci.yml` triggers on a push to `candidate` as well as `main`.
4. **A green candidate is promoted by the candidate workflow.** `candidate.yml`, projected from
   the CiWorkflows rows, runs when CI completes on `candidate`, and on success fast-forwards
   `main` onto the commit through the API (`force=false`) and starts `promote.yml`. The move is
   made with the workflow token, which starts no workflow run, so `main` does not run CI again
   on a commit CI just judged; Promote judges the commit by the check runs recorded against its
   sha, which the candidate run wrote, and Release runs after Promote as before. `main` has no
   ruleset and no branch protection, and the default token permission is read, so the job
   declares `contents: write` and `actions: write`. `Candidate.promote!` makes the same move
   from a checkout when the workflow did not.
5. **A red candidate never touches `main`.** `Candidate.observe!` reads it (`CandidateRed`);
   `Candidate.reject! --confirm` keeps local `main`'s tip on `rejected/<sha>` (the candidate's
   commits and whatever landed after them), resets local `main` to `origin/main`, files one
   `red-<cause>` Work item per failing cause (the failed jobs grouped by lesson kind, else by job
   name with the shard suffix left off) and names the authors and branches it carried in
   `CandidateRejected`, which the event tap carries to every session that follows it. It
   refuses by name with no candidate, a candidate that is not red, or an unclean local `main`.
6. **Direct pushes to `main` refuse.** The pre-push hook refuses a push of `main` that does not
   carry `hecks.candidatePromotion=<the pushed commit>` (`main moves only by promotion of a
   green candidate`). The owner's `HECKS_OWNER_PUSH` still passes: it is the recovery path
   should the gate itself break. The candidate ref is held to the train like `main`.
7. **The MainIntegration saga keeps working.** Its CI observation reads the candidate's run
   first while the gate is on and answers `candidate_passed` or `candidate_failed`, so the run
   ends green or red while the red flag, which hears `passed` and `failed`, stays where it is: a
   red candidate is not a red `main`.

The gate is a repository switch, `git config hecks.candidateGate`, defaulting to the Hecks
world's `gate "Candidate", enabled: false` row. `Candidate.enable! --confirm` and
`Candidate.disable! --confirm` flip it with no landing in between; the train and the hook read
the same setting. Landing this change changed nothing.

## Consequences

- `main` is green by construction while the gate is on: every commit on it passed CI at that
  exact sha, or has the tree of one that did.
- The red flag, `RedFlag.kick!` and the restore are left in place but are not raised by the
  gate: a red candidate raises nothing and is rejected instead. They remain for a red `main`
  reached through the owner's override or a tree-match promotion whose run on `main` fails.
- One candidate at a time means the coordinator boards in order: land, board, observe, then
  board the next. A refusal names the candidate and the next command.
- A tree-match promotion still starts a CI run on `main` (the push is made with the
  coordinator's token); nobody waits for it.
- The candidate ref is moved over a settled candidate; `main` is never forced.
