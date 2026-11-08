# Interviews are the beginning of work

**Status:** Proposed. Date: 2026-11-07. Supersedes the interview shape of
[ADR 0088](0088-an-ai-driven-interview-records-what-an-expert-says-and-drafts-the-first-domain.md):
its typed findings, its `planned` to `underway` ceremony, its single `expert`, and its keeping the
chapter out of the Hecks domain. Its purpose stands: a domain, and now any piece of work, starts from
a conversation whose every line traces to something someone said. Reviewed by the architect on
2026-11-07 ("sound with changes"); the amendments are folded in below.

## Context

Work in this repository begins in conversations. The owner and an agent talk, a recommendation is
made, an answer comes back, and then a Work item, an ADR or a bluebook line is written from what was
said. The conversation itself is not kept, so the ticket cannot say where it came from and the ADR
cannot cite the exchange that settled it. The interview of ADR 0088 was built to keep exactly this,
but only for one thing, an expert describing a business, and it is strict in ways that block the
wider use:

- **Typed findings.** An interview holds a finding per kind (a thing, an action, a rule, a field, a
  transition), each with its own accept and reject commands. A conversation about a tools ADR has
  none of these kinds; a decision cannot be recorded in it.
- **A fixed bar to conclude.** `Conclude` needs an accepted thing and an accepted action
  (`lib/hecks/sme/bluebook/sme.bluebook`, in `Conclude`, the accepted-thing and accepted-action `given`s). An
  interview that settled one decision cannot end.
- **A ceremony and one expert.** An interview is `planned`, then `underway`, and names a single
  `expert`. A planning talk between the owner and an agent, or between agent roles, has no seat.
- **Accepted findings cannot be revised.** A correction mid-interview has nowhere to go.
- **Outside the Hecks domain.** The chapter is booted only by `hecks interview`
  (ADR 0088, decision 1), so nothing in Tickets can react to its events, and a Work item cannot cite
  the interview it came from.

Today's conversation holds the proof. The 2026-11-07 session that produced
[ADR 0190](0190-tools-dissolve-behind-ports-and-kept-data-is-read-from-the-committed-world.md), and the
one that produced this record, were each an interview in everything but the record: a subject, a
sequence of questions and answers, recommendations, corrections, and then work.

What exists to build on:

- `Adr.Draft` and `Work.Plan` in the Tickets bluebook (both role Maintainer), with the Work item
  already able to cite the decision it carries out.
- The agent triggers `Planning.Request` and `PlanReview.Request`, which `delegate.bluebook` reacts to
  with policies (`StartThePlannerOnPlanningRequest`, and the one on `PlanReviewRequested`), and which
  the board's `plan` and `review` actions and `agents.html` call by name.
- The refusal that an agent role never takes an owner decision (`Issue` in `agents.bluebook`).
- Optimistic concurrency per aggregate ([ADR 0035](0035-optimistic-concurrency-and-per-key-locking-close-the-lost-update-gap.md)).

## Decision

1. **Work comes from a concluded interview.** An interview is the beginning of work. One interview
   hands on no Work row, or one, or many. Anyone holds one: the owner or an agent role. The Work item
   cites the interview and the point it came from.

2. **An interview holds exchanges and Points.** A **Point** is the one open unit of what an interview
   establishes:
   - `kind`, any word the participants use (`work`, `decision`, `rule`, `thing`, `action`, and others
     as they arise);
   - `statement`, in the participants' words;
   - the exchange it cites;
   - a state: proposed, then accepted or rejected;
   - `supersedes`, optional, naming the earlier Point a correction replaces.

   The unit is a **Point** because `Finding` is already an aggregate in Tickets and in CiSpeed, and
   `Claim` is already the outbox's dispatch claim. A point is an entity inside `Interview`, as
   ADR 0088's finding was. This reverses 0088's rejection of a separate `Finding` aggregate (its
   Alternatives considered, "A separate `Finding` aggregate", line 58): that record deferred the
   aggregate until findings needed correcting after the fact, and `supersedes` is that need. Keeping
   the point inside the interview still holds, because a correction names a point of the same
   interview; the reversal is only that corrections are now in the model.

3. **Concluding needs at least one exchange and nothing left open.** Every Point is accepted,
   rejected or superseded. There is no required kind: an interview that settled one decision
   concludes. Whether anything remains open is kept on the Interview by policies reacting to each
   point's events, because a rule cannot look inside a list (the reason 0088 gave its counts).

4. **Each accepted Point fans out on its own event.** Accepting a Point emits `PointAccepted`, which
   carries its kind and statement. Policies keyed on the kind react:
   - `work` calls `Work.Plan` (role Maintainer), citing the interview;
   - `decision` calls `Adr.Draft`, so a draft ADR exists for the decision;
   - a discovery kind (`thing`, `action`, `rule`, and the rest) is a bluebook line, held for the
     discovery projection and checked at conclusion.

   Nothing fans out from `InterviewConcluded`: a rule cannot look inside a list, so the work of
   turning points into rows belongs to the event that carries one point. Conclusion is the gate that
   lets the interview be committed, not the trigger.

   Splitting a large piece of work into Work rows is not done by the interview that found it. It is a
   follow-on interview with the planner that cites the first. `Planning.Request` and
   `PlanReview.Request` stay in Agents: they are the triggers an agent session starts from, wired to
   the board, `agents.html` and the delegate policies. Interviews emits the event that requests the
   planner and does not take them over.

5. **Participants are open, and one holder records.** A participant is a person or an agent role. The
   holder calls `Interview.Record` on every turn, with the question, the answer, the speaker and any
   Points proposed. The first `Record` is an explicit create-or-append command with `created_by`: it
   opens the interview, and the `Plan`, `Begin` and `expert` of 0088 go. Two writers appending to one
   interview are settled by optimistic locking (ADR 0035), not by a second command. The grilling skill
   calls `Interview.Record` so that what it asks and hears is kept as it happens.

6. **Interviews is its own bluebook, shipped in the gem, and attached to the Hecks domain.** Its
   events cross to Tickets (`PointAccepted` reaches `Work.Plan` and `Adr.Draft`) and to discovery. The
   SME chapter shrinks to the discovery projection: the generator that turns accepted discovery
   points into bluebook text, and nothing that holds a conversation.

   **Where it sits under [ADR 0163](0163-hecks-is-one-context-in-task-modules-and-a-bang-is-the-only-sign-of-a-write.md).**
   Interviews is a task module of the one Hecks context, grouped with the other maintenance work, and
   its commands are listed as the commands of that context. Attaching has costs, accepted here: the
   bluebook is booted by every `hecks` command, which adds boot time, and it enters the Ruby against
   Rust conformance comparison, so it must run in both.

7. **Memory by default; local SQLite in an overlay; the concluded record is committed.** Interviews
   persists in Memory like every other tooling domain. A developer who wants an open interview to
   survive a restart opts in with a SQLite hecksagon in a local overlay, never in the committed world.
   When an interview concludes, a projection writes it to `docs/interviews/<reference>.md`, and that
   file is committed with the ADR it produced. Hecks's own interviews are committed. A discovery
   interview with an outside expert is never committed, because it can hold client details
   (ADR 0088, Consequences, line 50): its record stays with the developer.

8. **A recommendation is a proposed `decision` Point.** The answer accepts it, rejects it and puts
   another beside it, or delegates ("your call"), in which case the point records who decided. A
   decision is settled by the participant it was put to, within the limits of that participant's role:
   an agent role does not take an owner decision (`agents.bluebook`, `Issue`), and that refusal
   stands. Delegation is recorded, not assumed.

9. **Any participant proposes; a turn that reopens the subject stays in the interview.** The
   convention is that a turn which returns to the subject belongs to the interview that holds it,
   and a new subject opens a new interview that cites the exchange it came from. This is a convention
   of the holder, not a rule the bluebook enforces.

10. **The checks on discovery points.** A discovery Point is a line of bluebook text, and
    `model_check` runs on directories, not strings. At conclusion the projection stages the accepted
    lines into a file in a temporary directory and checks that. That `model_check` accepts such a
    staged file is unproven and is the first thing the build shows.

11. **What retires.** The Ruby behind 0088's interview moves out as the Interviews bluebook takes its
    place:
    - `lib/hecks/tools/interview_run.rb`, `interview_aggregate.rb`, `interview_session.rb` and its
      directory (`agent_state.rb`, `catalog.rb`, `manual_findings.rb`, `proposals.rb`),
      `interview_agent.rb`, `interview_draft.rb`, `interview_record.rb`, `interview_shape.rb` and its
      directory (`lifecycle.rb`);
    - the `Launch.Interview` command and its `InterviewRequested` event in
      `lib/hecks/hecks/start/start.bluebook` (the command near line 109, the
      `ConverseWhenRequested` policy near line 176), and the `interview` entries of `hecks.world`;
    - the `SME::Interview` aggregate and its `sme.hecksagon`.

    What the generator and the agent port still serve (`lib/hecks/ports/agent.rb`, the `ClaudeCode`
    adapter, the scripted double) stays. [ADR 0190](0190-tools-dissolve-behind-ports-and-kept-data-is-read-from-the-committed-world.md)
    dissolves the `tools` directory behind ports; these files leave it by deletion, not by a move.

12. **The first interviews are the 2026-11-07 ones.** The conversation behind ADR 0190, then the one
    behind this record, are recorded by replaying their exchanges through the new commands, so the
    replay tests the commands. It happens only after the commands exist. The data of the old SME
    interviews is dropped: it lived in Memory for one session each and was never kept.

## Alternatives considered

- **Keep the SME chapter and loosen its `given`s.** Rejected: the typed kinds, the ceremony and the
  single expert are the shape, not a few rules. Loosening them leaves a chapter still outside the
  Hecks domain, which Tickets cannot react to.
- **Fan out from `InterviewConcluded`.** Rejected: the rule language cannot look inside a list, so a
  policy there could not make one Work row per accepted `work` point. One event per accepted Point
  needs no list.
- **Fold `Planning` and `PlanReview` into Interviews.** Rejected for now: they are agent triggers
  that the delegate policies, the board and `agents.html` call by name. Interviews emits the planner
  request instead, and folding stays open.
- **A CI bug as a one-exchange interview.** Dropped: `BugCiWatch` starts on `Bug.BugFixed`, so a CI
  bug already has its own start and gains nothing from a conversation.
- **Name the unit Finding or Claim.** Rejected: Tickets and CiSpeed hold a `Finding`, and the outbox
  holds a `Claim`. A Point collides with neither.
- **Persist open interviews in SQLite by default.** Rejected: persistence defaults to Memory, and a
  committed world that names SQLite would put every checkout's interviews in a database no one asked
  for. The overlay gives the choice to the developer.
- **Commit every interview.** Rejected: an interview with an outside expert can hold client details.
  Only Hecks's own interviews are committed.
- **Leave the record to the ADR alone.** Rejected: an ADR holds the decision and not the exchange
  that reached it, which is the thing this record exists to keep.

## Consequences

- A Work item and an ADR can each cite the exchange they came from, and the repository holds the
  conversation beside the decision.
- Any conversation can be an interview, so the grilling skill, a planning talk and an architect's
  review leave the same record without a one-off script.
- Every `hecks` command boots one more bluebook, and Interviews joins the Ruby against Rust
  conformance comparison. These costs are accepted in decision 6.
- The old interview tools and the `Launch.Interview` command go, and `hecks interview` as a verb goes
  with them. A caller of it moves to `Interview.Record`.
- A committed `docs/interviews/` appears in the tree, and a reviewer reads a decision with the
  exchange behind it.
- A discovery interview with an outside expert is not committed, so the client details ADR 0088
  warned of stay out of the repository.
- The `kind` is any word, so a typo in a kind reaches no policy and does nothing. A kind that no
  policy keys on is a recorded point and no more; the board can list such points so that none is
  lost unseen.
- `model_check` of staged bluebook lines is unproven. If it does not hold, discovery points are
  committed as text and checked when a developer merges them, as 0088 already left merging by hand.

## Open items

- Whether `Planning` and `PlanReview` fold into Interviews once the board and `agents.html` call
  Interviews directly.
- Whether the grilling skill's turns can all be recorded without the holder naming each speaker.
