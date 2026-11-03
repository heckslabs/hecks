# A bad release is fixed forward or reverted by a named rule

**Status:** Proposed. Date: 2026-10-30. Planned for 7.0.0. The choice between the two options
below is the owner's, by the same rule that approves a release; this record lays the options
out so it can be made in one reply. Step 47 of
[ADR 0163](0163-hecks-is-one-context-in-task-modules-and-a-bang-is-the-only-sign-of-a-write.md)'s
plan.

## Context

7.0.0 is the largest release the repository has cut. ADR 0163 lands every shape change of the
release as one era on the push train's database: the two new aggregates, the moved commands, the
collapsed families, the renames of the adapter-word aggregates and verbs, and the retirement of
the positional `Hecks::CLI` forms behind the bang rule. The `hecks-rust` split of
[ADR 0164](0164-hecks-distills-to-a-core-that-no-satellite-is-needed-to-build.md) is 7.1.0 and
outside this record.

A release that turns out bad is found at one of three points, and each point has a different
blast radius.

1. **The era is refused on the train.** The train's launcher boots against its own database
   (`hecks_train`). If the committed edges do not lead the held era to the new shape, the boot
   refuses, and the train stops carrying every session's pushes until a person fixes it. Nothing
   has been published yet; `main` holds the change, `stable` has not moved.
2. **A client's upgrade breaks.** Both clients pin a git sha of the `edge` line in their Gemfile
   (`gem "hecks", git: …, ref: "<sha>"`), not a gem version, and take a newer hecks by moving
   that pin. Their `bin/host`, Makefile, Dockerfile and CI call `hecks build.build_host` and a
   few other commands by name. The bang rule, the renames and the retired forms reach a client
   only when its pin moves, so a broken upgrade is one client at a time and is undone by moving
   the pin back.
3. **A bug is found after the gem is published.** `release.yml` has tagged `v7.0.0`, pushed the
   gem to rubygems.org, published the client package to npm and created the GitHub Release.
   Anyone resolving `hecks` by version now gets 7.0.0; the two clients, pinned by sha, do not.

What the repository can already do at each point:

- **Rehearse before the push.** `RehearsalRun.request!` runs the mint against a copy of the
  train's data and answers `would_mint`, `would_refuse`, `needs_edge` or `cannot_boot`
  ([ADR 0104](0104-rehearse-an-era-before-minting-it.md)). ADR 0163 requires a `would_mint`
  answer before the 7.0.0 push, so point 1 is reached only through a rehearsal that passed.
- **Declare a rollback on every edge.** Each translation rule carries a `rollback` clause or is
  marked `irreversible`, and the pre-mint audit checks that every new edge declares one
  ([ADR 0083](0083-a-translation-edge-declares-its-own-rollback.md)). Executing a declared
  rollback, minting era N+1 with the earlier shape, is that record's second stage and is not
  built. Today a declared rollback is a reviewed statement of how to go back, not a command.
- **Certify before releasing.** `stable` only ever fast-forwards onto a commit every required
  check passed on; `edge` is the tag at its head, and a client pins a sha from that line. A bad
  commit on `main` blocks promotion but does not move `stable`.
- **Approve by trailer.** `release.yml` cuts a release only from a commit on `stable` whose
  message carries `Release-Approved-By: <name>`; a bump without it releases nothing.
- **Finish a half-cut release by re-running.** Every step of `release.yml` skips what already
  exists and never moves a tag that stands, so a release that stopped partway is completed by
  re-running it. The same property makes undoing a release something the workflow does not do.
- **Pin the previous version.** A client whose upgrade breaks moves its sha back to the last
  `edge` commit it ran on. That is a one-line change in its Gemfile and needs nothing from
  hecks.

## Decision

Two options, each as a named rule. The owner picks one, and the pick is recorded in this record's
status line.

### (a) Fix forward only

A bad 7.0.0 is corrected by 7.0.1 through the normal lanes: the fix lands on `main`, every
required check passes, `stable` fast-forwards, the owner approves the bump by trailer, and
`release.yml` cuts it. Nothing is yanked, no tag moves, and the train's era stays where the
release put it.

- **At point 1** (era refused) this is the only option in any case: the fix is a corrected edge
  committed to `main`, rehearsed again, and pushed. The train waits until it is. Other sessions'
  pushes queue behind it.
- **At point 2** the client moves its pin back while 7.0.1 is cut, then forward again.
- **At point 3** 7.0.0 stays on rubygems.org and npm with a known defect until 7.0.1 is up. A
  version resolver that asks for the newest gets the defect for as long as that takes.

Costs: the time to land and certify 7.0.1, which is bounded by the gate and CI on `main`; one
release the changelog has to describe as a fix; and the window at point 3 during which the
defect is the newest published version. Nothing else in the repository changes, and no record
written under the 7.0 shape is touched.

### (b) Revert to 6.x

A bad 7.0.0 is withdrawn and the previous line restored. Because the release is one era, one tag
and one set of published packages, a revert is a set of steps that each have to be done, and
some of them the repository cannot do today.

1. **Code.** Revert the 7.0.0 commits on `main` (a revert commit, never a force-push), pass the
   gate and CI, let `stable` fast-forward onto the revert. `main` then holds the 6.x shape again.
2. **The train's era.** The train's database holds era N+1 with the 7.0 shape. Booting the
   reverted code against it is refused unless an edge leads N+1 back to the 6.x shape. ADR 0083
   says that edge is the declared rollback of the forward edge, minted as era N+2; executing it
   is the unbuilt second stage. Until it is built, a revert means either a database snapshot
   restore of `hecks_train` (which discards every row written since the snapshot, including
   push-train runs of other sessions) or hand-writing the reverse edge and minting it as a
   normal forward era, which is the work the second stage would automate.
3. **Records written under the 7.0 shape.** Tickets records live in their own database
   (`~/.claude/hecks-dev/tickets.db`) and AgentRun records in `agent_run.db`, both outside the
   train. A revert of the train's era does not touch them, but a `Work` row planned under the
   7.0 Tickets shape stays in that shape; if the Tickets bluebook moved in 7.0.0, those rows need
   their own reverse edge or stay unreadable by 6.x.
4. **Published packages.** The gem can be yanked from rubygems.org (`gem yank`), the npm
   package deprecated or unpublished within npm's window, and the GitHub Release marked as a
   pre-release or deleted. The tag `v7.0.0` stays, because the ruleset refuses moving or
   deleting a tag that stands, so the version number is spent: the corrected line is 7.0.1 or
   7.1.0 whichever way this goes.
5. **Clients.** Pinned by sha, so untouched by the yank. A client that already moved its pin
   moves it back.

Costs: a revert commit that has to pass the same gate as the release did; the train's era, which
either loses other sessions' records to a snapshot restore or waits on hand-written reverse
edges; the published packages withdrawn by hand, outside any workflow; and the version number
lost either way. Step 2 is the one that can stop every session's pushes.

### Who decides, and when

The owner decides, by the rule that approves a release: the `Release-Approved-By` trailer. A
revert is the same kind of statement a release is (what the certified line is), so it carries
the same approval and nothing less.

Option (b) is cheaper than (a) only before point 1 is passed: while the 7.0.0 change is on `main`
but the train has not minted the era, a revert is a revert commit and nothing else, and the
packages do not exist to withdraw. Once the train holds era N+1, a revert costs the era work in
step 2, which (a) never pays. Once the gem is published, (b) adds the withdrawals in step 4,
which (a) also never pays. The window in which (b) is the cheaper answer closes when
`PushTrain.board!` carries the 7.0.0 change.

### Recommendation

Fix forward only, with (b) allowed only inside the window above. Every mechanism the repository
has points one way: `stable` and `edge` only move forward, `release.yml` only finishes and never
undoes, a tag never moves, a client pin is a sha and not a version, and an era rollback is
declared on every edge but executed by none yet. Option (a) uses all of them as built; option (b)
asks for the one piece that is not built (executing a rollback) at the moment it would be under
the most pressure, and its only shortcut (a snapshot restore) throws away other sessions' work.
The rehearsal requirement in ADR 0163 is what makes (a) safe to rely on: point 1 is reached only
through a `would_mint` answer, so the era that a fix-forward has to live with is one that was
already proven to mint. A 7.0.1 is a known cost; a revert past the window is an unknown one.

## Open questions

- **Whether a rubygems yank is ever acceptable.** A yank removes a version from resolution but
  not from installs that already hold it, and the repository's own clients do not resolve by
  version. The case for it is a release that leaks a secret or ships a destructive default; the
  case against is that `release.yml` is built never to undo, and a yank is the one undo done by
  hand with no record. If the answer is yes, the condition should be written down here and the
  yank done through a `PublishingRun` command that records it.
- **Whether the train's era can be rolled back without stopping other sessions' pushes.** A
  snapshot restore cannot; a reverse edge minted as era N+2 could, if the second stage of
  ADR 0083 is built and the train's launcher accepts the new era the way it accepts any mint.
  Until then, a train-side revert is a stop-the-world step, and that is the strongest reason to
  keep option (b) inside its window.

## Consequences

- The release approval and the revert approval are the same rule, so there is one place to look
  for who may say what the certified line is.
- The 7.0.0 plan gains a stop line: once `PushTrain.board!` has carried the change, the answer
  to a bad release is a fix forward, and the team plans for 7.0.1 rather than for a withdrawal.
- The second stage of ADR 0083 becomes the thing that would widen the window. Building it is a
  separate decision and is not planned for 7.0.0.
