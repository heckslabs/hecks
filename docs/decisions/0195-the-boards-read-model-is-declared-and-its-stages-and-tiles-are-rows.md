# The board's read model is declared, and its stages and tiles are rows

**Status:** Proposed. Date: 2026-11-07. Narrows
[0154](0154-hand-written-code-is-a-kernel-an-adapter-or-a-projector.md) (a hand-written file is a
kernel, an adapter or a projector) to the PipelineBoard (`lib/hecks/pipeline_board`), and follows
[0190](0190-tools-dissolve-behind-ports-and-kept-data-is-read-from-the-committed-world.md) in
method: it names where each body of code in one directory goes under that rule. Points 1, 2 and 6
are decided and have Work items; points 3 to 5 are considered and held until point 2 has shown
what a row can carry. Reviewed by the architect on 2026-11-07 ("sound with changes"); the
amendments are folded in below. The owner's interface review of the same day is the first
instance of the declared shape (Target layout).

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
  them.
- **The server is the board's own.** `pipeline_web/server.rb`, `stream.rb`, `snapshot.rb` and
  `act_route.rb` are a hand-rolled `TCPServer`: a fixed route table, a digest-diffed state push
  over Server-Sent Events, a background snapshot with no rescue, one `POST`. Nothing in them reads
  the PipelineBoard's rows; they would serve any domain's queries the same way.
- **The diagrams read the registry, not the board.** `pipeline_wiring.rb` with its graph, details
  and source, and the `wiring.html` and `sequence.html` pages, draw the policies, ports and
  adapters of whatever registry is booted. They are projections of IR, living in an adapter
  folder.
- **The readers are adapters.** `pipeline_github`, `pipeline_git`, `pipeline_tickets`,
  `pipeline_jobs`, `pipeline_journal`, `pipeline_disk` and `pipeline_fill`, with `probe.rb`,
  `cache.rb` and `session_context.rb`, run `gh`, `git`, `df` and the launcher and read job and
  journal files. They are what ADR 0154 calls an adapter, and they stay.

What is certain to go: the `Document` return, the verdicts coded in tile builders, the four copies
of one count, and the three copies of the handoff map. How much of the page code a projector
would save is not known until the rows exist, so this record claims no percentage.

## Decision

1. **The read model is declared on the aggregate.** The `PipelineBoard` aggregate gains a value
   object for every row the board shows, and each query returns it, typed:

   - `Reading`: one measure as read, `source` (the port), `measure`, `value`, `read_at`, and
     `unknown` (the reason, when the read failed). A failed read is a `Reading` with `unknown`
     set, never a special hash.
   - `Stage` (`name`, `position`, `state`, `count`, `detail`) and `Tile` (`id`, `label`, `value`,
     `unit`, `state`, `detail`, `trend_delta`, `trend_better`): what a query returns. Point 2
     declares the rows that produce them; the two are not the same kind of thing. A `Stage` does
     not carry the `Verdict` position that held: the page does not show it, so it is left out
     until a page does.
   - `CiRun`, `Job`, `WorkItem`, `Session`, `Event`: the rows the four tables and the feed carry
     today as untyped JSON, with the fields the pages read.
   - `Finding` gains `work_item` and `detail`, so a flag the fan-out raises is a `Finding` row and
     no third name is declared for it. A handoff between roles is the `Wiring` query's policy
     edge, filtered to the roles the world names; no `Handoff` object is declared.

   `Stages` returns `list_of(Stage)`, `CiRuns` `list_of(CiRun)`, `SlowestJobs` `list_of(Job)`,
   `OpenWork` `list_of(WorkItem)`, `Sessions` `list_of(Session)`, `Events` `list_of(Event)`, and a
   new `Tiles` returns `list_of(Tile)`. `Document` is deleted. The runtime's `OutsideAnswer#shaped`
   then refuses an adapter that answers the wrong shape, which no spec can today. The first spec
   of the first slice pins that a query's `returns list_of(<value object>)` is built and checked
   row by row for an adapter's answer, and that a `Reading` with `unknown` set is accepted as a
   row; the precedents are aggregate attributes and one query each, so the claim is checked before
   anything is built on it.

2. **A stage and a tile are rows.** Two member tables beside `Verdict`, and they are declarations,
   not answers: `StageRow` (`name`, `position`, `source`, `measures`, `count`, `detail` template)
   and `TileRow` (`id`, `label`, `position`, `source`, `measure`, `unit`, `lower_is_better`,
   `window`, `detail` template). A template names its measures in braces
   (`"{planned} / {started} / {done}"`). One builder walks the rows: it takes the `Reading`s a
   source gave, asks `Rules.verdict` with the row's name, fills the template, and computes a
   tile's trend from the window's two halves. `strip.rb`, `metrics.rb`, `ci_tiles.rb`,
   `work_tiles.rb`, `disk_tiles.rb` and `tile_kit.rb` are deleted. Every tile the review found
   deciding in code gets `Verdict` rows, and "Main red for" is stated once: the red flag row and
   the red tile read one `Reading` (red since, minutes red, the first red and the last green sha).

   The builder is an adapter under ADR 0154: it is the `Pipeline` port's adapter (`PipelineStages`,
   `pipeline_board.ports.hecksagon`), which composes the other ports' answers into `Stages`,
   `Tiles` and `Snapshot`, and it decides nothing the rows do not say. Whether `Stages` and `Tiles`
   should instead be declared as a composition in the bluebook, with no `Pipeline` port at all, is
   left open until the rows exist (Alternatives). `rules.rb` stays the one evaluator.

   One reading, one place: a `TileRow` names the `Reading` it shows and a `StageRow` names its
   `measures`, so a count appears where its row puts it and nowhere else. A tile that would restate
   a strip node is not declared.

3. **Considered, not decided: the server as a generic read-model adapter.** The `Web` port already
   exists (`pipeline_board.ports.hecksagon`, `asks "Listen"`) and `PipelineWeb` is its adapter. If
   the server becomes generic, it does so as a replacement of that adapter, not as a second port:
   a module that serves any bluebook's typed queries as `GET /api/state`, its `Events` as
   `GET /api/events`, and its `ActionRule` rows as `POST /api/act`, with `Act` run through the
   aggregate so an `ActRequested` event records every step the page takes. `ActionRule` stays a
   PipelineBoard value object, so the module stays in `lib/hecks/pipeline_board/adapters`; nothing
   in the repository needs a second board today, and the Serve module is not changed. The server's
   properties are stated once when it is rewritten: a snapshot thread that survives an exception
   and reports its age, a timeout per reader, and bounded reads (the event tap tailed by byte
   offset, one ticket read per cycle, the stream fed from the snapshot). Until then those are the
   open Work items `board-snapshot-freeze-guard` and `board-bounded-reads`, which a coder may take
   on the hand-written server.

4. **Considered, not decided: the pages as a projector.** A `project_board_page` operation beside
   `project_glossary` in `Regeneration::OPERATIONS` (`lib/hecks/hecks/adapters/codebase/regeneration.rb`)
   would read the PipelineBoard IR (the value objects of point 1, the `StageRow` and `TileRow`
   tables, `ActionRule`, `Finding`, `Setting`) and write `page.html`, `agents.html`, `answer.js`
   and the text panel's templates to `lib/hecks/pipeline_board/generated/`, each file opening with
   a `GENERATED by hecks project_board_page from the PipelineBoard bluebook` banner, with its own
   `--check` for drift, since `regenerate_corpus!` and the drift job cover `rust/src/generated`
   only and would not catch a hand-edited page until the operation is added to them. The agents
   page's handoff map would come from the `Wiring` edges filtered to the world's roles, which
   deletes the `ROLES`, `EDGES` and `ROLE_EVENTS` tables and the SVG. `stream.js` would stay a
   hand-written static asset. The saving is the duplication between the page, the agents page and
   the text panel, not their whole size: the drawing logic becomes templates the projector holds.
   Decided after point 2 lands and shows how much of a panel a row carries.

5. **Considered, not decided: the diagrams move to core.** `PipelineWiring` with its graph,
   details and source would become a projection of any booted registry beside the structure,
   dispatch and statechart diagrams in `lib/hecks/projections/diagrams`, and `wiring.html` and
   `sequence.html` would move beside the glossary's HTML projector. Decided with point 4.

6. **The readers stay hand-written adapters, one per port.** GitHub, Git, Tickets, Jobs, Journal,
   Disk and Fill answer the typed rows of point 1 and nothing else; `probe`, `cache` and
   `session_context` stay as their shared kit. `PIPELINE_BOARD_LAUNCHER_ROOT` goes: an
   environment variable is a one-off override or a secret
   ([0132](0132-an-environment-variable-is-a-one-off-override-or-a-secret.md)), and this one
   splits the readers between two stores (the landed branches are read from an empty Memory
   registry while the Work items come from the launcher). The board reads the one world the
   checkout declares.

7. **Nothing new in the language, and no Rust.** Typed `returns`, `list_of`, value objects and
   `member` rows are grammar both parsers accept today. The PipelineBoard is tooling, persisted in
   Memory, and not in the Rust corpus, so `regenerate_corpus! --check` is the only Rust gate.

## Target layout: the first instance of the declared shape

The owner's interface review (Finding `board-layout-steering-first`) is the first set of
`StageRow` and `TileRow` rows, written here so the hand-written page is not polished toward a
different layout first:

- **The first screen answers three questions, in this order.** Is `main` green and pushed: the
  origin sha, its age, the open train pull request with its red checks. What the orchestrator is
  doing and what is stuck. What ships next: the version. The pipeline strip, Work, Sessions, Local
  main, Train, CI, Promote, Release, is the only section above the fold; the train pull request
  lives in the Train node and the next version in the Release node, as `StageRow` measures. The
  metric tiles and the CI charts come below.
- **"Needs attention" goes.** One `Stuck` list replaces it: what, since when, who owns it (the
  orchestrator's or the fixer's run, linked), one deep link, and no owner action buttons. It is a
  query returning typed rows, judged by `Verdict` rows, not a page-side filter over tiles.
- **One reading, one place.** A tile that restates a strip node (dispatched sessions, commits not
  pushed) is not declared; the strip node carries the number.
- **`/runs/` and `/trains/` get the board shell and an index.** `/trains/` lists the open train
  pull requests with their checks and `/runs/` the live runs; a run key or a pull request number in
  a brief is a link. The deep links already highlight in place (`board-highlight-not-page`).

Of the owner's review items filed as Work items, this record absorbs into point 2 the ones that
are a row or a reading: `board-main-red-for-fix` (one red reading), `board-origin-push-age` and
`board-train-row-open-pr` (the Train node's measures), `board-session-idle-and-verdict` (a
`Verdict` and `Setting` row for a stalled session), and the `Verdict` half of
`board-small-findings`. It leaves to coders on the hand-written code the ones that are a reader or
a server property: `board-snapshot-freeze-guard`, `board-bounded-reads`,
`board-answer-one-rule`, `board-answer-reply-delivers`, `board-plan-reviews-from-planreview`,
`board-delivery-reader-rotations`. `board-pruner-role` is closed when the page reads the roles the
adapter already reads from the world, which point 4 would do and a coder may do first.

## Alternatives considered

- **A `read_model` for the board.** The `read_model` construct aggregates stored records (count,
  median, group by; ADRs 0050, 0052, 0126). The board's readings are answers from ports, not
  records in a store, so a `read_model` has nothing to read. Member rows on value objects, which
  `Verdict` already uses and which `outside_answer.rb` shapes port answers into, fit.
- **Keep `Document` and generate from the JSON.** A projector would then read the adapters' Ruby
  to learn the shape, which is what ADR 0154 forbids a projector to need: it reads a chapter or
  the IR, never code.
- **A `serve` port in the Serve module for the server.** The `Web` port and its adapter exist; a
  second port for the same purpose is a duplicate, and a second adapter on `Web` fails at boot.
  Moving the server into Serve would also make a core module read `PipelineBoard::ActionRule`,
  pointing the core at a tooling domain. If a second board ever needs the server, the port
  declaration moves to Serve first and `Web` binds to it.
- **Drop the `Pipeline` port and declare `Stages` as a composition.** `Stages`, `Tiles` and
  `Snapshot` derive only from the other queries' answers, so the bluebook could say so and the
  composing adapter would go. Attractive, and not decided here: it needs the rows of point 2 to
  exist first to see whether a declaration can carry the detail templates and the trend windows.
- **Decide the projector now.** Points 4 and 5 are bets on a projector that does not exist. A
  record that decides them before point 2 shows what a row carries would be a guess with a number
  on it.
- **One slice.** The two decided slices land independently and each leaves the board working; one
  branch would hold the board for weeks and collide with every open board item.

## Consequences

- The board's shape is checkable. An adapter that answers the wrong row is refused by the runtime,
  and a rule hidden in a tile builder has nowhere left to hide: the state of every stage and tile
  traces to a `Verdict` row.
- A new tile is a `TileRow` and its `Verdict` rows; a new stage measure is a word in a `StageRow`.
  The owner's layout is rows, so the hand-written page is reshaped once, by rows, not polished
  toward it by hand.
- The readers do not shrink. The `gh`, `git`, `df`, job-file and journal reading stays hand-written,
  which ADR 0154 allows and expects.
- The projector and the diagram move wait on point 2. When it lands, a short amendment to this
  record settles points 3 to 5 with the measured saving.
- Filing the Work items is a manual step from the main checkout: a worktree's Tickets store is
  Memory (the launcher says so when it boots there), so `Work.plan!` run inside one records nothing
  the pipeline sees.
- Plan, as ordered Work items (each lands on its own, through `landing.finish!`, with the board
  working after it):
  1. `adr0195-01-read-model-declared`: the value objects, the typed `returns`, `Reading`,
     `Finding` with `work_item` and `detail`; the readers answer rows; `Document` deleted; the
     first spec pins `list_of` returns and the unknown `Reading`. Area `lib/hecks/pipeline_board`.
  2. `adr0195-02-stage-tile-rows`: `StageRow`, `TileRow`, the `Tiles` query, the one builder in the
     `Pipeline` adapter; the stage and tile modules deleted; the Target layout as the first rows;
     folds `board-main-red-for-fix`, `board-origin-push-age`, `board-train-row-open-pr`,
     `board-session-idle-and-verdict` and the `Verdict` half of `board-small-findings`. Area
     `lib/hecks/pipeline_board`.
  3. `adr0195-03-readers-worldbound`: `PIPELINE_BOARD_LAUNCHER_ROOT` removed, the readers read the
     one world, the rest of `board-small-findings`. Area `lib/hecks/pipeline_board/adapters`.
     Independent of slice 2.
