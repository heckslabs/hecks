# A red main reverts its one bad merge by policy

**Status:** Accepted. Date: 2026-11-17. Asked for by the Work item
`a-red-main-reverts-its-one-bad-merge-by-policy`. It carries out item 4 of decision 0212.

## Context

The 2026-11-16 local trial found two real reds, each reverted by hand in 17 to 30 minutes, and one false
red (a spec that fails only on the owner's machine). The check never named the culprit merge: the search
for it stopped as soon as any landing moved main, which happens within minutes at four landings an
hour, and every rescue hid why, so the refusal carried no line at all.

## Decision

1. **The adapter reports facts; the bluebook decides.** The `MainVerifying` port gains `Bisect`
   (`MainVerification#bisect`, `MainIntegration::Bisecting`): the last verified commit, the first merge
   whose own specs fail (commit, branch, subject, spec, example), whether those specs are red at the
   last verified commit too, whether a revert already stands in the range, and whether the merge never
   left local main. It runs after the verification's copy is released, one probe at a time. Nothing is
   reverted, marked or raised there.
2. **The deliver bluebook chooses.** On the failure a run is parked on (`MainVerificationFailed`, the
   retry's), `RedEpisode` records one decision per red run: `Revert` (a merge is red, its specs pass at
   the last verified commit, no revert stands in the range), `Park` (a revert already stands in the
   range: one revert per red episode, then the owner decides) or `Acquit` (no merge turned a spec red
   that was green at the last verified commit, so a spec red only on this machine reverts nothing).
3. **The revert is the push train's command.** `SendTrain.Unland` (the port ask is `Revert`, which
   `GitTrain#revert` answers) is dispatched by `RevertTheCulprit`, so it keeps the line's turn;
   `MainVerification` never calls `GitTrain::Reverting`. The revert is a new commit: nothing is forced
   and no history is rewritten.
4. **"Main is red" has one owner, the `RedFlag`.** `RaiseTheFlagWhenReverting` raises it before the
   revert is made, so `Landing` and the train already refuse by name (`main is red: flag <id>`); there
   is no second marker. A revert of a merge that never left local main is verified as its own run
   (`VerifyTheRevert`), and a pass lowers the flag. A merge that reached `origin/main` leaves the flag
   standing for the owner and CI.
5. **"One revert per episode" is read from git.** The fact is a revert commit in the first-parent range,
   so a new process reads it too; the Memory aggregate records the decision, it does not hold the guard.
6. **The refusal always says something.** A failure the run is parked on carries a line naming the first
   bad merge and spec, or `no first bad merge: <reason>`. The head moving no longer stops the search: the
   merges between two fixed commits do not change.

## Consequences

- After a revert of a merge, main still holds the branch's commits, so rebasing or merging the old branch
  again brings in nothing. The `SendTrain` report names the revert commit in full and the rule: land the
  work again as a revert of that revert plus new commits, or as fresh commits. It opens with the reason
  `Unland` was given, which is the episode's finding.
- The culprit's Work item is reopened on `RedEpisode.EpisodeRevertMade`, which carries the Work item, the
  finding, the revert and that report; the report is the reopened item's detail. A revert that is refused
  reopens nothing: the merge still stands, and the owner is told of the refusal.
- The search is capped at six probes plus one base probe. A range with more merges than the cap can bisect
  gives no culprit and reverts nothing.
- `RedEpisode.EpisodeReverting` carries the branch (the Work item key), spec and example the search found;
  the policies that reopen the Work item are in the Tickets bluebook.
