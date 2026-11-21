# The coder's work is a process manager: Specify, Implement, Verify, Land

**Status:** Proposed. Date: 2026-11-20. Asked for by the owner (2026-11-18) as part of the epic
`the-pipeline-runs-on-its-own-bluebooks`. A sketch, not wired: nothing loads it, and building it is
later work.

## Context

One coder session today writes the spec and the code that passes it, so a spec can be bent to fit the
code it was meant to check. The owner asked for two separate agent runs: one writes the failing spec,
a different one makes it pass and may not edit it. The hand-offs between them, and the ones after,
are today a mix of events and waiting helpers.

Two records already turned waits into events: `coder-never-idles-on-plan-review` (the coder ends its
turn and the verdict resumes it) and `landing-is-fire-and-forget` (the submission starts a landing
job and returns). This record extends the same rule to the spec hand-off. No helper sits idle waiting
for another's answer.

## Decision

The coder's work on one work item is a `process_manager`, correlated by the work item's name. The
grammar accepts `process_manager` today; [ADR 0180](0180-a-process-manager-has-one-name-in-the-language-and-the-runtime.md)
settles the word as `saga` and moves the keyword, so the sketch is renamed with it and nothing else
in it changes. Verify and Land are the contexts that already exist (the gate, CI, Landing, SendTrain);
the sketch hears their events and declares none of their names.

| Step | Who | Ends in |
|---|---|---|
| Specify | agent run 1 writes the failing spec | `SpecificationWritten` |
| Spec check | the check runs the spec on main | `SpecificationChecked` (fails for the stated reason) or `SpecificationRejected` (passes, or fails for another reason: back to Specify) |
| Implement | agent run 2, a different run, makes it pass | `ImplementationPassed`, `ImplementationGaveUp`, or `SpecificationSentBack` with a reason |
| Verify | the gate and CI | passed or failed (the existing gate and CI events) |
| Land | Landing, then the push train | `BranchLanded`, or red on main |

Implement may not edit the spec. `Specification` owns the digest of the spec; `Implementation.Start`
carries it, and `Implementation.Pass` is refused unless the digest it finishes with is the one it
started from. It may send the spec back, with a reason, instead of bending it.

### Compensations

| Failure | Goes back to |
|---|---|
| The spec check rejects the spec | Specify |
| Implement gives up, or sends the spec back | Specify |
| CI red | Implement, with the failing examples |
| Red after landing | The existing automatic revert: `a-red-main-reverts-its-one-bad-merge-by-policy` reverts the one bad merge and `a-red-episode-reopens-the-culprits-item` reopens the work item, which re-enters at the step its reason names |

The red-after-landing case is not a leg of the sketch: the red-flag mechanism already does it, and the
sketch only needs the reopened work item to start again. Verify's two legs (CI red back to Implement,
a pass on to Land) are wired when the gate and CI events are bound, which is the build, not the sketch.

### Where the state lives

`model_check` warns when a `process_manager` runs on a persistence adapter without `save_saga`: its
state advances in-process and is lost on restart ([ADR 0170](0170-saga-state-is-as-durable-as-the-aggregates-it-coordinates.md)).
Memory has no `save_saga`; Heki, Sqlite, Postgres and PostgresEra do. The coder's work spans agent runs
that outlive any one process, so the sketch's hecksagon binds it to Sqlite, and the saga's leg, memory
and compensations survive a restart with the aggregates it coordinates:

```ruby
Hecks.hecksagon "CodersWork" do
  persisted_by "Sqlite"
end
```

Persistence defaults to Memory elsewhere; this domain is the exception because its whole job is to
outlast a process.

### The sketch

The bluebook below was loaded and run through `exe/hecks ModelCheckRun.model_check!` on 2026-11-20 and
came back clean: one bluebook, no dead states, no unreachable protocol steps. It lives in this record,
not in a `.bluebook` file, because the corpus sweeps every unrouted `.bluebook` in the tree as a
bootable domain; a file would wire it. Building it moves it under `lib/hecks/coder/` with its hecksagon.

```ruby
Hecks.bluebook "CodersWork" do
  vision "A work item is specified by one agent run and made to pass by another, then verified and landed; each hand-off is an event, and a failure sends the work back to the step that can fix it."

  core

  # The failing spec one run writes. It owns the digest of the spec, so no later step can change
  # what the spec says without this aggregate seeing it.
  aggregate "Specification" do
    description "The failing spec written for one work item, and whether it fails on main for the stated reason."

    identified_by :work

    attribute :work,   WorkName
    attribute :digest, SpecDigest
    attribute :reason, StatedReason, optional: true

    value_object "WorkName" do
      attribute :value, String, matches: :present
    end

    value_object "SpecDigest" do
      attribute :value, String, matches: :present
    end

    value_object "StatedReason" do
      attribute :value, String, matches: :present
    end

    lifecycle :status, default: "requested" do
      transition "Write"  => "written",  from: %w[requested rejected]
      transition "Check"  => "checked",  from: "written"
      transition "Reject" => "rejected", from: "written"
      mark :terminal, "checked"
      # An agent run does the work in each of these, so the record rests while it runs.
      mark :rests, "requested", "written", "rejected"
    end

    command "Request" do
      goal "Ask one agent run to write the failing spec for a work item"

      attribute :work, WorkName
      sets :work

      emits "SpecificationRequested"
    end

    command "Write", from: %w[requested rejected] do
      goal "Record the spec the first agent run wrote, by its digest"

      reference_to Specification
      attribute :digest, SpecDigest
      sets :digest

      emits "SpecificationWritten"
    end

    command "Check", from: "written" do
      goal "Record that the spec fails on main for the stated reason"

      reference_to Specification
      # Restated so the event carries them to the hand-off.
      attribute :work,   WorkName
      attribute :digest, SpecDigest
      attribute :reason, StatedReason
      sets :reason

      emits "SpecificationChecked"
    end

    command "Reject", from: "written" do
      goal "Record that the spec passes on main, or fails for another reason"

      reference_to Specification

      emits "SpecificationRejected"
    end
  end

  # The second agent run, which makes the checked spec pass without editing it.
  aggregate "Implementation" do
    description "The second agent run's attempt to make a checked spec pass; it may hand the spec back with a reason."

    identified_by :work

    attribute :work,   WorkName
    attribute :digest, SpecDigest
    attribute :reason, SendBackReason, optional: true

    value_object "WorkName" do
      attribute :value, String, matches: :present
    end

    value_object "SpecDigest" do
      attribute :value, String, matches: :present
    end

    value_object "SendBackReason" do
      attribute :value, String, matches: :present
    end

    lifecycle :status, default: "started" do
      transition "Pass"     => "passed",    from: "started"
      transition "GiveUp"   => "given_up",  from: "started"
      transition "SendBack" => "sent_back", from: "started"
      mark :terminal, "passed", "given_up", "sent_back"
      mark :rests, "started"
    end

    command "Start" do
      goal "Hand a checked spec to a different agent run, carrying the spec's digest"

      attribute :work,   WorkName
      attribute :digest, SpecDigest
      sets :work
      sets :digest

      emits "ImplementationStarted"
    end

    # The digest the run ends with must be the digest it started from: an edited spec is refused.
    command "Pass", from: "started" do
      goal "Record that the spec now passes and was not edited"

      reference_to Implementation
      attribute :finished_digest, SpecDigest
      given("the spec was not edited") { finished_digest.value == digest.value }

      emits "ImplementationPassed"
    end

    command "GiveUp", from: "started" do
      goal "Record that the implementer could not make the spec pass"

      reference_to Implementation

      emits "ImplementationGaveUp"
    end

    command "SendBack", from: "started" do
      goal "Hand the spec back to Specify with the reason it cannot be satisfied"

      reference_to Implementation
      attribute :reason, SendBackReason
      sets :reason

      emits "SpecificationSentBack"
    end
  end

  # Verify and Land are the existing Landing and Clearance contexts; this domain only hears them
  # by the events they already emit, named in the ADR, so it declares none of their names.
  process_manager "CodersWork" do
    correlates_by :"work.value"
    starts_on Specification::SpecificationRequested

    transition Specification::SpecificationWritten  => "spec_checking", from: "specifying"
    transition Specification::SpecificationRejected => "specifying",    from: "spec_checking"
    transition Specification::SpecificationChecked  => "implementing",  from: "spec_checking" do
      dispatch Implementation::Start, with: { work: :work, digest: :digest }
    end
    transition Implementation::ImplementationPassed => "verifying", from: "implementing"
    transition Implementation::ImplementationGaveUp => "specifying", from: "implementing"
    transition Implementation::SpecificationSentBack => "specifying", from: "implementing"
  end
end
```

Three things the check taught, kept in the sketch: an event carries only what its command declares, so
`Check` restates `work` and `digest` for the hand-off to read them; `given` is the word for a command's
precondition; and a state an agent run works in is marked `rests`, since a run is the wait, not an idle
helper.

## Alternatives rejected

- **One agent writes spec and code.** The spec can be fitted to the code. Rejected by the owner.
- **Poll for the spec.** A helper that waits for the spec to land is the idle wait the two earlier
  records removed.
- **Persist in Memory.** Cheaper, and forgets which leg a work item was on at the next restart.
