# An interview is recorded from a speaker-labelled transcript

**Status:** Proposed. Date: 2026-11-19. Builds on
[ADR 0194](0194-interviews-are-the-beginning-of-work.md), after its Interviews bluebook
(`lib/hecks/interviews/interviews.bluebook`) and its concluded record
(`lib/hecks/interviews/concluded_record.rb`) landed. Reviewed by the architect on 2026-11-19
(plan review run `bd3a8129`, verdict sound); its notes are folded in below. Nothing here is built
yet: each decision is carried out by a follow-on Work item (Open items).

## Context

ADR 0194 keeps an interview one turn at a time: the holder calls `Interview.Record` with the
speaker, the answer and, optionally, the question, and proposes Points citing an exchange by its
number. That suits a conversation the holder is part of, such as a grilling or a planning talk. It
does not suit the commonest interview with an outside party: a call, recorded and transcribed,
read after it ends. A transcript of an hour's call holds hundreds of spoken lines, each already
labelled with its speaker. Recording it a turn at a time is a loop someone writes, and in this
repository a loop no command covers is a gap in the bluebook, not a script to write.

Three further gaps show once a transcript is the source:

- **A Point does not say who said it, or which words.** It cites an exchange by number, and the
  exchange holds a whole answer. On a call, one answer can run a minute and carry several points,
  and two speakers can disagree. A reader of the record cannot see which words a point rests on.
- **A disagreement or a gap has no place.** When two participants say different things, or nobody
  said something the model needs, the holder has nothing to record but a note outside the
  interview. The interview then concludes with the question open and unseen.
- **Accepting each point is not how a call ends.** A good interviewer reads back what was heard
  ("so a booking is held for a day, and only a manager can release it early?") and the
  participants confirm it. Asking an outside expert to accept forty points one by one is not a
  conversation anyone has. The confirmation of a read-back is the acceptance.

The participants also need a plan in their own language, not a bluebook. And a call with a client
holds client details, which ADR 0194 decision 7 already keeps out of the repository. This record
says how a transcript keeps that promise when its record is written.

## Decision

1. **A transcript becomes turns in one step, through a port.** Reading a transcript file is
   imperative, so it sits behind a port, and the domain half is declared:
   - `Interview.Transcribe` takes the reference, the subject, the keeping, the transcript's path
     and its `format`, and emits `TranscriptRequested`.
   - A policy on `TranscriptRequested` asks the `Transcribing` port to `Read`, in the same shape as
     the `Beating` port's `Take` (`lib/hecks/hecks/hecks.hecksagon`, and its policies in
     `delegate.bluebook`). The port answers `TranscriptRead`, carrying the turns, or refuses with
     `TranscriptUnread`, naming the line it could not read.
   - A policy on `TranscriptRead` triggers `Interview.RecordTranscript`, which appends every turn to
     `exchanges` in one command and emits one `TranscriptRecorded`. A transcript is one act, so it
     is one event, not one per line.
   - The port is declared in `interviews.hecksagon`. Its one adapter, `Transcribing`, sits beside
     the bluebook it serves, in `lib/hecks/interviews/adapters/`, as a `.adapter` declaration and
     its `.rb`, because Interviews ships in the gem as its own bluebook (ADR 0194 decision 6). The
     adapter reads both formats, with `format` as data: `text` (lines of `Name: words`) and `vtt`
     (WebVTT cues with `<v Name>` voice tags).
   - One spoken line is one turn, with its speaker and its words. A line with no label continues
     the speaker before it. A transcript turn carries no question: deciding which line answers
     which is a reading of the conversation, so it is left to the Points, not guessed by the
     adapter. The question part stays optional in `Exchange`, as it is today.
   - `RecordTranscript` creates the interview or appends to the one that exists, as `Record` will
     once the create-or-append Record work lands. If the bluebook cannot append a list of values
     in one `sets`, that grammar gap is the first follow-on (an append of each value of a list),
     and no loop is written around it.

2. **A Point keeps its speaker and its passage.** `Point`, and `ProposePoint` with it, gain
   `speaker` and `passage`: who said it, and the words of the cited exchange it rests on, quoted.
   A `given` cannot look inside the list of exchanges, so the rule cannot check that the speaker
   and the passage match the exchange cited. That is trusted to the holder, as the statement is,
   and the record shows all three side by side, so a reader can see a mismatch. The concluded
   record and the plan (decision 5) quote the passage under each point.

3. **A split or a gap is a point of kind `question`.** When participants disagree, or a thing the
   model needs was never said, the holder proposes a Point of kind `question`. Its statement names
   the split or the gap, and a new optional `concerns` list, on both `Point` and `ProposePoint`,
   names the points it concerns. It stays proposed until it is answered, so the existing open-point
   count keeps `Conclude` refused while it stands. It is answered by a later Point whose
   `supersedes` names it, and `Supersede` settles the question. No new aggregate is needed: a
   question concerns points of the same interview, which is why ADR 0194 kept Point inside
   Interview.

4. **A confirmed read-back accepts the points behind it.** The holder reads back a summary naming
   the points behind it. The participants' confirmation is an exchange like any other.
   - `Interview.ConfirmReadBack` takes the read-back's number, the confirming exchange as its
     source, and the numbers of the points it covers, and emits `ReadBackConfirmed`.
   - A policy cannot fan out over a list, and ADR 0194 decision 4 needs one `PointAccepted` a point,
     so the holder then accepts each named point with `Accept`, citing the read-back. `Point` gains
     `read_back`, which `Accept` sets. The participants are asked once, and the record shows each
     point accepted by that read-back.
   - `Accept` gains `given("a question is answered, not accepted") { kind != "question" }`, so no
     read-back closes a question by accepting it.
   - That a cited read-back really named the point cannot be checked, because a rule cannot look
     inside its list. This is trusted to the holder, as the passage is, and shown side by side in
     the record.

5. **A plain-language plan is projected from the accepted points.** From a concluded interview, a
   plan projection beside the concluded record writes the accepted points of kind `work`,
   `decision` and `rule` as sentences in the participants' words, each followed by its quoted
   passage and speaker. The participants read it in place of a bluebook. When the discovery
   projection of ADR 0194 (decisions 6 and 10) exists, the plan is written beside its draft model,
   so the two can be read side by side. The plan is a projection of the interview's IR, as every
   other output is, not text written by hand.

6. **A client interview is never committed to Hecks.** A transcript of a call with an outside
   party is recorded with keeping `local` from its first step.
   - This amends `ConcludedRecord`. Today its `path` answers nothing for a keeping that is not
     `committed`, so a local interview has no record at all. A local interview's record, its plan
     and any draft model are now written, but to a directory the developer names, outside the
     checkout, and the projection refuses a target path inside the repository for a local
     interview, by name.
   - The transcript file itself is never added to the repository. This is enforced: `Transcribe`
     refuses a transcript path inside the checkout, so a transcript is read from where the
     developer keeps it and never copied in.

## Alternatives considered

- **One `Record` a spoken line.** Rejected: the step and the events multiply by the length of the
  call, and someone writes the loop. A transcript is one act and is recorded as one.
- **The adapter pairs questions with answers.** Rejected: deciding that a line answers another is
  a reading of the conversation, which is the holder's, and is shown in the Points. The adapter
  only splits lines and labels.
- **One adapter a format.** Rejected: a port has one adapter, and the formats differ only in how a
  line and its label are found, so the format is data.
- **A separate `Question` aggregate.** Rejected: a question concerns points of one interview, the
  reason ADR 0194 kept Point inside Interview, and the open-point count already holds the
  conclusion back.
- **A read-back accepts its points by policy.** Rejected: the rule language cannot look inside a
  list, so a policy cannot accept each named point. One event a point stays.
- **Commit a redacted record of a client interview.** Rejected: a redaction that misses one name
  puts a client's details in a public tree. The record stays with the developer.

## Consequences

- A call's transcript becomes an interview with one command, and nobody writes a script to load
  it.
- A reader of a record sees which words each point rests on and who said them, and can see a
  mismatch the rules cannot catch.
- Disagreements and gaps are kept in the interview and hold its conclusion back, so none is lost.
- A call ends as calls do, with a read-back, and the record still holds one acceptance a point for
  the policies keyed on kind.
- The participants get a plan in their own words; the model and the plan come from the same
  points.
- A local interview now has a record, kept outside the checkout. `ConcludedRecord` changes, and
  its specs with it.
- The speaker, the passage and a read-back's coverage are trusted to the holder; the record shows
  them, the rules do not check them.

## Open items

Each is a follow-on Work item. Each bluebook change is checked with
`exe/hecks model_check_run.model_check` on `lib/hecks/interviews`, then regenerated and conformed.

- The `Transcribing` port and adapter, `Transcribe` and `RecordTranscript` (decision 1), after the
  create-or-append Record work. If a list cannot be appended in one `sets`, that grammar change
  comes first.
- `speaker` and `passage` on `Point` and `ProposePoint` (decision 2).
- Kind `question` and `concerns` on `Point` and `ProposePoint` (decision 3).
- `ConfirmReadBack`, `read_back` on `Point`, and the `given` on `Accept` (decision 4).
- The plan projection (decision 5), and its placing beside the draft model once the discovery
  projection exists.
- The local record outside the checkout, and both refusals of a path inside it (decision 6).
- Whether `model_check` accepts a `list_of(PointNumber)` on an entity, for `concerns`; it was not
  checked when this was written.
