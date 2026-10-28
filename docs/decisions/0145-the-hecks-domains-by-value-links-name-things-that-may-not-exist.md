# The hecks domain's by-value links name things that may not exist

**Status:** Accepted. Date: 2026-10-27. Finished by ADR 0151 on 2026-10-28.

## Context

`model_check` reports two kinds of finding over the Hecks domain that read as unfinished work:
`:key_by_value`, an attribute whose value-object type is another aggregate's identity type but
which is not a `reference_to`, and `:orphaned_reference`, a `reference_to` whose target can end
with no policy acting on the holders. The DDD review listed them as a gap: identity copied by
value instead of stated as a link.

A `reference_to` is not only documentation. At write time the command refuses a reference whose
target record does not exist, and the reference is stored as the target's identity rather than as
the value object. So converting a by-value link is right when the target is a stored record that
exists when the referencing command runs, and wrong otherwise. Each finding was read against that.

## Decision

Of the by-value links, one is sound to convert and the rest are left as they are, for one of three
reasons.

**The target never holds records.** `Era.domain`, `RehearsalRun.domain`, `Build.domain` and
`FuzzRun.domain` hold a domain's path, and `Introspection` is keyed by that path. `Introspection`
declares queries only, each answered by the runtime through a port, so it has no records. A
reference to it would be refused by every one of those commands.

**The target is recorded later, or by the run itself.** `PublishingRun.version` is the version the
run tags, and the `Release` for it is created by that run's own `Tag`. A reference would require the
record the command exists to make.

**Same type, different thing.** The value-object type matches by name, not by meaning.
`PublishingRun.client_version` and `ir_version` are the client package's version and the IR's, not
gem releases. `Operation.url` is any address an operator checks, not only a recorded `Host`.
`Tenant.domain` names a domain that may deploy by a kind other than a Lambda, and `LambdaTarget`
is one kind. `Bug.commit`, `Patch.commit` and `Improvement.commit` are the commit a thing was found
or opened at, and a `Clearance` exists only once CI has run on that commit.

**Sound, and built.** `Adr.settles` names a `Finding` of the same bluebook, a stored record, and
an ADR that settles a finding is refused if no such finding exists. It is now
`reference_to Finding, as: :settles, optional: true` on the aggregate and on `Draft`. The conversion
turns a stored one-field value object (`{"value": "<finding>"}`) into a reference (the finding's bare
key), so the Tickets shape moved and the edge `2-cd96d8.bluebook` carries a rule:
`derive :settles, as: "settles.value"`. No Adr row exists in any database on this machine, so it was
rehearsed against a generated copy: a scratch database minted at the old shape, an Adr that settles
a finding and one that settles none, dumped, and rehearsed with `RehearsalRun.request!`. The
audit read `{"value":"F-1"}` as `"F-1"` and left the null as null, and the rehearsal answered
`would_mint` with no refused row. A stored `settles` naming a finding that was never recorded
migrates as it stands; only a new write is refused.

Of the orphaned references, none gets a policy, and each is acknowledged on the holder (ADR 0151).

- **`Bug` to `Sweep`, and `Improvement` to `Angle`.** A sweep concluding or abandoning, or an angle
  built or discarded, completes the thing the holder cites. It does not end the holder, which stays
  a true record of what was found or landed (the completion-not-death case ADR 0121 names).
- **`Ticket` and `Patch` to `Bug`.** A ticket is an issue in an outside tracker, and a patch is a
  pull request. Each is written by the process that made it true (`gh pr view`, the tracker's
  answer). A policy that closed either when its bug is withdrawn would record a close that did not
  happen on GitHub or in the tracker, so the ledger would be wrong about the world.

## Alternatives considered

- **Convert every finding.** It makes the warnings go away and breaks the commands: the four
  `Introspection` links and `PublishingRun.version` would refuse every write.
- **Add a policy for each orphan, so the warning clears.** It trades an honest warning for a
  reaction that misstates what happened outside the ledger.
- **Weaken the check.** Out of scope here, and the right place is a finding the declaration can
  acknowledge with a reason (ADR 0137 item 6), so each of these says so on its own aggregate.

## Consequences

- Every by-value link and orphaned reference this ADR left alone now says so on the declaration,
  with the reason above as its text (`acknowledges :key_by_value, "...", of: :commit`, ADR 0151),
  and `model_check` reports neither kind for the Hecks domain or QualityControl.
- No policy was added. A policy is sound only where the referenced record truly ends, in the same
  bluebook, with no side effect outside it, and none of these qualifies: two targets finish
  rather than end, and two holders mirror an outside system.
- `Adr.settles` was the one real by-value gap in this domain, and it is closed.
