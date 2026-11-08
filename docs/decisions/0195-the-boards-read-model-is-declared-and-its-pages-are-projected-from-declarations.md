# The board's read model is declared, and its pages are projected from declarations

**Status:** Proposed. Date: 2026-11-07. Narrows
[0154](0154-hand-written-code-is-a-kernel-an-adapter-or-a-projector.md) (a hand-written file is a
kernel, an adapter or a projector) to the PipelineBoard (`lib/hecks/pipeline_board`), and follows
[0190](0190-tools-dissolve-behind-ports-and-kept-data-is-read-from-the-committed-world.md) in
method: it names where each body of code in one directory goes under that rule. Records the
owner's finished target design (Tickets finding `board-target-design`, 2026-11-07), which settles
what an earlier draft of this record held open. Reviewed by the architect on 2026-11-07 ("sound
with changes"); its amendments are folded in, and where the owner's design overrides one the
Alternatives say so. Nothing here is built; the slices are Work items, listed in Consequences.

## Context

The PipelineBoard is the local page that shows the pipeline from a Work item to a release, read
live through ports: CI from GitHub, local `main` and the train from git, the Work items through
Tickets, the sessions from each job's state, the events from the journal. Its bluebook already
holds every decision the board makes as rows: `Verdict` says which state a stage or a tile is in,
`Setting` the numbers the rules compare with, `Finding` what the fan-out may flag, `ActionRule`
what the page may run. The adapters hold no rule of their own; `rules.rb` reads the rows and
answers.

The rows govern a small part of the directory (6,847 lines at `ab49f6b0d`). The rest has a shape
no rule in the repository describes:

- **Every query returns an opaque `Document`.** `Stages`, `CiRuns`, `SlowestJobs`, `OpenWork`,
  `Sessions`, `Snapshot`, `Wiring` and `Events` all `returns Document`, a value object with one
  `text` field holding JSON (`pipeline_board.bluebook`, the `Document` value object). The runtime
  can verify a typed answer: a query that `returns list_of(TimelineEvent)` has each row built and
  checked as that value object (`lib/hecks/runtime/query_interpreter/outside_answer.rb`, the
  `Timeline` query of `deliver.bluebook`, the `ProjectedFile` rows of `operate.bluebook`). The
  board uses none of that, so nothing downstream can be generic: a page, a text panel or a
  projector has to know the hash each adapter happened to build.
- **A stage and a tile are methods.** Each stage in `pipeline_stages/strip.rb` and each tile in
  `ci_tiles.rb`, `work_tiles.rb` and `disk_tiles.rb` is the same four steps: read a measure from a
  section, call `Rules.verdict`, format a detail line, build a hash. Where a step was skipped the
  owner's review found the rule in code: the disk, lead, carry and release tiles decide without a
  `Verdict` row; the CI stage counts a cancelled run as failed while the text panel asks
  `CheckConclusion`; "Main red for" picks the oldest green run instead of the latest
  (`ci_tiles.rb`, `red_for`). The text `Panel` under `pipeline_stages/panel` renders the same
  hash a second time, by hand.
- **The same number is shown up to four times, with different values.** Dispatched sessions
  "0 of 8" beside "7 busy", "4 of 8 started" and "7 working"; commits not pushed "57" beside
  "Local main 57 ahead" and "Train last push 0.7 h". Each is a tile or a strip node computing its
  own count from the same section, because no row says which reading a node shows.
- **The handoff map is written three times.** `agents.html` holds the roles and the events between
  them in its `ROLES` and `EDGES` tables and again in a hand-drawn SVG, and `agent_roles.rb` holds
  `ROLE_EVENTS`, while the board's own `Wiring` query already derives every policy edge from the
  Agents bluebook. `agent_roles.rb` reads the roles from the Hecks world's `agent_roles` line; the
  page's two maps and `ROLE_EVENTS` do not, so the `pruner` role the world declares is missing from
  them. The page also addresses the owner ("blocked on you", Promote and Dismiss buttons) when the
  pipeline's rule is that the orchestrator answers and the owner only steers.
- **The server is the board's own.** `pipeline_web/server.rb`, `stream.rb`, `snapshot.rb` and
  `act_route.rb` are a hand-rolled `TCPServer`: a fixed route table, a digest-diffed state push
  over Server-Sent Events, a background snapshot with no rescue, one `POST`. Nothing in them reads
  the PipelineBoard's rows; they would serve any domain's queries the same way. `POST /api/act`
  runs the launcher around the `Act` command, so no `ActRequested` event records what the page did.
- **The diagrams read the registry, not the board.** `pipeline_wiring.rb` with its graph, details
  and source, and the `wiring.html` and `sequence.html` pages, draw the policies, ports and
  adapters of whatever registry is booted. They are projections of IR, living in an adapter
  folder.
- **The readers are adapters.** `pipeline_github`, `pipeline_git`, `pipeline_tickets`,
  `pipeline_jobs`, `pipeline_journal`, `pipeline_disk` and `pipeline_fill`, with `probe.rb`,
  `cache.rb` and `session_context.rb`, run `gh`, `git`, `df` and the launcher and read job and
  journal files. They are what ADR 0154 calls an adapter, and they stay. One of them reads a
  second store through `PIPELINE_BOARD_LAUNCHER_ROOT`, an environment variable
  ([0132](0132-an-environment-variable-is-a-one-off-override-or-a-secret.md) allows one only as a
  one-off override or a secret), so the landed branches come from an empty Memory registry while
  the Work items come from the launcher.

What is certain to go: the `Document` return, the verdicts coded in tile builders, the four copies
of one count, the three copies of the handoff map, and the owner as an actor on the page. How much
of the page code a projector saves is the duplication between the page, the agents page and the
text panel, not their whole size, so this record claims no percentage.

## Decision

The purpose the design serves: one page a steering owner reads in ten seconds, in this order: is
`main` green and shipped; what is stuck and who owns it; what ships next. Everything else is
drill-down. The owner takes no action on the page except the two steering forms (a goal for the
planner, a plan review request for the architect), which go to the orchestrator.

1. **The read model is one typed `Snapshot`.** The `PipelineBoard` aggregate declares the rows
   and the `Snapshot` query returns them; `Document` is deleted.

   - `Reading`: `key`, `label`, `value`, `unit`, `state` (`ok`, `attention`, `failed`, `working`
     or `unknown`), `note`, `since`, `link`, `source` (the port it came from), `fresh_at`. Every
     number on the board is one `Reading` with one key, rendered in one place. A failed read is a
     `Reading` in state `unknown` with the reason as its note, never a special hash.
   - `Stage`: a `Reading` plus `order`; the seven strip nodes `work`, `sessions`, `local_main`,
     `train`, `ci`, `promote`, `release`.
   - `StuckItem`: `kind` (`blocked_run`, `red_main`, `stalled_session`, `train_blocked`,
     `owner_ask`), `what`, `since`, `owner_run`, `link`.
   - `RunCard`: `run`, `role`, `session`, `condition`, `work_item`, `idle_seconds`, `last_word`
     (`routed` or `blocked`), `link`.
   - `TrainCard`: `pr`, `head_sha`, `commits`, the check counts (`green`, `red`, `skipped`),
     `red_jobs`, `auto_merge`, `age`, `state`, `superseded`.
   - `ReleaseCard`: `latest_tag`, `next_version` (from `version.rb`), `changelog_heading`,
     `stable_has_version_commit`, `holds` (what blocks the cut).
   - `Snapshot`: `generated_at`, `stale_seconds`, `stages`, `readings`, `stuck`, `roles`, `runs`,
     `train`, `release`, `events`. The web page, the text snapshot and the MCP door render this
     one `Snapshot`.

   A state is decided only by a `Verdict` row and a threshold only by a `Setting` row; the disk,
   lead, carry and release-age tiles get their rows, so no adapter decides a colour. The runtime's
   `OutsideAnswer#shaped` then refuses an adapter that answers the wrong shape, which no spec can
   today. The first spec of the first slice pins that a query's `returns list_of(<value object>)`
   is built and checked row by row for an adapter's answer, and that a `Reading` in state
   `unknown` is accepted as a row: the precedents are aggregate attributes and one query each, so
   the claim is checked before anything is built on it.

2. **A page is a declaration.** A `Page` declaration in the bluebook names its sections in order,
   each naming the query it renders and its kind: `strip`, `stuck`, `chips`, `tiles`, `chart`,
   `table`, `feed` or `card`. The board has three `Page` declarations:

   - `/`: the header (title, "updated HH:MM", a stale banner when `stale_seconds` is over 30, the
     links Agents, Diagrams, Runs, Trains); the strip, the only section above the fold, whose
     Train node carries the `TrainCard` inline (pull request number, commits, checks, red job
     names), whose Release node carries `next_version` and `holds`, and whose Local main node
     shows the age of the last origin push, never the last local landing; the Stuck list, newest
     first, one row each (kind badge, what, owner run linked, since), "nothing stuck" when empty,
     no buttons; the Roles chips, one only for a role that is working (role, work item, age), idle
     roles on one line, the pruner included; and below the fold, collapsed by default with the
     state remembered per viewer: Key metrics (only readings not on the strip: CI success, median
     wall, commit-to-green, landed-to-pushed, work finished per day, disk), CI on main (the wall
     chart with the goal line drawn and the axis capped at twice the goal with an overflow mark;
     the failed-jobs chart only when a run has failures, else one line), Sessions (live only by
     default, with session, role, work item, idle and detail, no Delete), Fan-out (lanes, plus
     "would start N, skipped M" grouped by reason), Work items (planned, by step, paginated) and
     Events (time, run name, event, the reaction chain inline, no raw aggregate ids).
   - `/agents`: the handoff map generated from the `Wiring` query, with no "You" node (the sender
     is the role that issued the command); plan reviews, answered first with the verdict's full
     first sentence and waiting ones as one-line rows; handoffs collapsed by sender, receiver and
     event with a count and the work item; the two steering forms, which say they go to the
     orchestrator.
   - `/runs/` and `/trains/`: an index and a detail page each, on the board shell. A run shows its
     `RunCard`, its brief collapsed, its events, and links to its work item, session and train. A
     train shows its `TrainCard`, its checks table, its red jobs linked to the job page, and the
     trains it superseded.

   Copy rules hold on every page: never "you"; each state word has its one-line meaning under the
   heading; no tooltip-only help; run names, not uuids.

3. **A generic page projector lives in core Hecks, not in the board.** It renders a `Page`
   declaration from a `Snapshot` into HTML and the Server-Sent Events it listens to, with the
   theme tokens and one renderer per section kind. It reads IR (the `Page`, the value objects, the
   `Verdict` and `Setting` rows), never the board's Ruby, which is what ADR 0154 asks of a
   projector. Its output carries a generated banner and is regenerated through a
   `project_board_page` operation beside `project_glossary` in `Regeneration::OPERATIONS`
   (`lib/hecks/hecks/adapters/codebase/regeneration.rb`), with its own `--check`, because
   `regenerate_corpus!` and the drift job cover `rust/src/generated` only. `wiring.html` and
   `sequence.html` move to core as the diagram projector, usable by any domain.

4. **A generic serve verb lives in core.** It opens a declared read model on a local port: a
   snapshot thread that rescues, keeps refreshing and reports `stale_seconds`; a gather with a
   timeout per reader so one slow port does not hold the rest; Server-Sent Events fed from the
   snapshot's digest, with no re-read per reader; `GET /api/state` as the `Snapshot`, the pages of
   point 2, and `POST /api/act` for the `ActionRule` rows. `Act` goes through the aggregate: the
   route dispatches `Act`, and a policy on `ActRequested` asks the launcher, so every step the page
   takes is an event. The board's `Web` port keeps its declaration and binds to the core adapter.

5. **The I/O adapters stay hand-written, behind declared ports.** GitHub, Git, Tickets, Jobs,
   Journal, Disk and Fill answer the typed rows of point 1 and nothing else; `probe`, `cache` and
   `session_context` stay as their shared kit. One declared live-store port replaces
   `PIPELINE_BOARD_LAUNCHER_ROOT`: the board asks it for the Work items, runs and landings of the
   store the owner's checkout declares, and the environment variable goes.

6. **Acceptance.** `page.html`, `agents.html`, `answer.js` and `stream.js` are deleted. Specs cover
   the `Snapshot` shape, every `Verdict` row, one golden render per section kind, the freeze case
   (a reader raising shows the banner within 30 seconds), and "each `Reading` key rendered once".
   The text snapshot and the web page are the same `Snapshot`.

7. **Nothing new in the language's parsers, and no Rust.** Typed `returns`, `list_of`, value
   objects and `member` rows are grammar both parsers accept today. The `Page` declaration is the
   one new construct, declared in the language's own bluebooks like `Verdict` rows are declared on
   the board's; it is read by the Ruby projector only. The PipelineBoard is tooling, persisted in
   Memory, and not in the Rust corpus, so `regenerate_corpus! --check` is the only Rust gate.

## Alternatives considered

- **A `read_model` for the board.** The `read_model` construct aggregates stored records (count,
  median, group by; ADRs 0050, 0052, 0126). The board's readings are answers from ports, not
  records in a store, so a `read_model` has nothing to read. Value objects that
  `outside_answer.rb` shapes port answers into fit.
- **Keep `Document` and generate from the JSON.** A projector would then read the adapters' Ruby
  to learn the shape, which is what ADR 0154 forbids a projector to need: it reads a chapter or
  the IR, never code.
- **Keep the server and the projector inside the board.** The architect's review asked for this:
  the `Web` port and its adapter exist, nothing in the repository needs a second board today, and
  a core module that read `PipelineBoard::ActionRule` would point the core at a tooling domain.
  The owner's design puts both in core anyway, and answers the finding this way: the serve verb
  and the projector read a `Page` declaration, `ActionRule` rows and typed queries as IR, the way
  every projector reads IR, and the board keeps its `Web` port and binds it to the core adapter,
  so no second port is declared and no core file names a board constant. The second board the
  review said did not exist is the deploy manager's and the timeline's, both filed.
- **Stage and tile rows (`StageRow`, `TileRow`) as the declaration.** An earlier draft of this
  record declared each strip node and tile as a row with a detail template and let one builder
  walk them. The owner's design keeps the idea and moves it up a level: a `Reading` carries its
  own key, label, unit and state, a `Stage` is a `Reading` with an order, and a `Page` section
  names the query and the kind, so the rows a builder would have walked are the typed answers
  themselves. No separate row table is declared.
- **Decide the projector later, after the rows show what they carry.** The architect proposed it
  and the earlier draft held points 3 to 5 open. The owner's design decides them, with the
  acceptance of point 6 as the measure instead of a line count.
- **One slice.** The six slices land independently and each leaves the board working; one branch
  would hold the board for weeks and collide with every open board item.

## Consequences

- The board's shape is checkable. An adapter that answers the wrong row is refused by the runtime,
  and a rule hidden in a tile builder has nowhere left to hide: every state traces to a `Verdict`
  row, every threshold to a `Setting` row.
- A new section is a line in a `Page` declaration; a new number is a `Reading` with a key; a new
  role is a word in the world. The hand-written page is reshaped once, by declaration, not polished
  toward the design by hand.
- The owner leaves the page as an actor. No button answers a session or promotes a lane; the Stuck
  list names the run that owns each item, and the steering forms go to the orchestrator.
- The readers do not shrink. The `gh`, `git`, `df`, job-file and journal reading stays
  hand-written, which ADR 0154 allows and expects.
- A second tooling board (the deploy manager's, the timeline's) costs its bluebook, its `Page`
  declarations and its readers, not a server and a page.
- Filing the Work items is a manual step from the main checkout: a worktree's Tickets store is
  Memory (the launcher says so when it boots there), so `Work.plan!` run inside one records nothing
  the pipeline sees.
- Migration, in order, each step mapped to the open Work items it is or absorbs. Bug fixes keep
  landing on the hand-written page while steps 1 and 3 are built, so the board stays useful; each
  fix becomes a `Verdict` row or a `Reading` when its step lands.
  1. **Typed read model and `Snapshot` shape** (point 1): `pipeline-board-read-models`. Absorbs
     the `Verdict` half of `board-small-findings` (disk, lead, carry, release decide by rows; one
     CI conclusion rule) and `board-session-idle-and-verdict` (a stalled-session `Verdict` and
     `Setting` row). The first spec pins the typed `list_of` return.
  2. **Bug fixes on the current page, meanwhile**: `board-main-red-for-fix`,
     `board-snapshot-freeze-guard`, `board-train-row-open-pr`, `board-origin-push-age`,
     `board-plan-reviews-from-planreview`, `agentrun-ledger-liveness`. Each lands as a reading the
     `Snapshot` keeps: one red reading, the `TrainCard`, the origin push age, a stored
     `PlanReview` verdict, a settled run ledger.
  3. **`Page` declaration and the generic projector** (points 2 and 3): `board-page-declaration`
     (the bluebook) and `page-projector-core` (core Hecks). Absorbs `board-pruner-role` (the roles
     come from the world) and the handoff-map half of `board-small-findings`.
  4. **Agents page from `Wiring`, and the no-owner copy sweep**: `pipeline-no-owner-board`,
     `board-agents-from-wiring`. Absorbs `board-answer-one-rule` (the server, not the page, says
     which sessions are blocked, and the page shows the Stuck list) and the Promote and Dismiss
     removal.
  5. **Detail pages and indexes on the shell**: `board-detail-pages`. Completes what
     `board-highlight-not-page` began.
  6. **Delete the hand-written pages**: `release-board-next-version` (the `ReleaseCard`),
     `board-bounded-reads` and `serve-verb-core` (point 4; absorbs the live-store port of point 5
     and `board-answer-reply-delivers`, since the act route is rewritten there), then the deletion
     of `page.html`, `agents.html`, `answer.js` and `stream.js` with the golden renders of point 6.
- Left to coders on the hand-written readers, outside these steps: `board-answer-superseded-hidden`
  and `board-delivery-reader-rotations` (reader behaviour, not shape), and `board-first-read-fast`
  (one `gh` call per run).
