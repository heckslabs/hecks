# The launcher lists contexts, and a bang is the only sign of a write

**Status:** Proposed. Date: 2026-10-30.

## Context

Bare `hecks` in a checkout prints every command and query of the Hecks domain as one wall. The
listing is a projection (`Projector::CliProjector`), so the wall is the model's shape shown back:

- **One bluebook in many files.** Every file under `lib/hecks/hecks/` declares
  `Hecks.bluebook "Hecks"`. The files read like contexts, but the IR holds one bluebook, so the
  launcher has one flat list. The file lines are arbitrary: `codebase.bluebook` holds
  `PublishingRun` and `PromotionRun`, which are release work; `custodian.bluebook` holds delivery,
  journal upkeep and operations side by side.
- **Grouped by record, not by task.** Each heading is an aggregate, so one task spreads across many
  headings. Projections live under `LanguageRun`, `KernelRun`, `RegenerationRun`, `Build`, `Launch`
  and `Introspection`; checks under `ConformanceRun`, `KernelRun`, `Build`, `ModelCheckRun`,
  `GateRun`, `StyleRun` and `Audit`; servers under `CorpusRun` and `Launch`.
- **Names that mislead.** `Release.tag!`, `mark_published!` and `verify!` only record; the tagging
  is `PublishingRun.publish!`. `SyntaxBootCache.rebuild!` records a rebuild; the clearing is
  `TestSuiteRun.clear_caches!`. The Ruby-against-Rust conformance checks sit under `Build`, not
  `ConformanceRun`. `InspectionRun` says flog and reek but holds `search` and `read_source`.
  `verify!`, `retire!` and `status` each name unrelated acts on different aggregates.
- **Bookkeeping is guessed.** A command is internal when its role is `System`
  (`cli_projector/command_specs.rb`), so a record-only verb whose role is not `System` is listed as
  an action.
- **Families spelled as separate commands.** The `project_*` verbs, the `build_*` verbs, the
  servers, the three spec runners and the language row moves are each one act on different
  targets.
- **Adapter words in domain names.** `PullRequest`, `Commit`, `Checkout`, `PushTrain`, and verbs
  like `squash` and `push`, name what git and GitHub do. Swapping the adapter would leave the
  domain speaking the old one's language.
- **No bang does not mean read.** A name without `!` reaches a command when one matches
  (`cli_runner/resolution.rb`), so `style_run.check_comments` and `Hecks::PushTrain.Board` run
  commands while looking like reads. `query` exists only to settle a name a command and a query
  share.

The gem's own `Hecks::CLI` table repeats part of the launcher (`run`, `docs`, `narrate`, `ir`,
`stores`, `model_check`, `smoke_test`, `project_diagrams`, `project_cli`, `mcp`) as positional
forms, the `legacy` list of the world's `launcher` setting.

## Decision

**The launcher lists contexts, and each context is its own bluebook.** Bare `hecks` prints a short
everyday list, the contexts with their `vision` lines, and the other bluebooks. `hecks <context>`
lists one context, commands and queries together. The existing `hecks <bluebook>` listing is the
mechanism; no section keyword is added.

The contexts, named for what the domain does and never for an adapter:

| Context | Aggregates |
|---|---|
| operations | Operation, Host, Introspection |
| quality | GateRun, StyleRun, InspectionRun, CodemodRun, TestSuiteRun, FuzzRun, ModelCheckRun, ScriptRun |
| build | Build, RegenerationRun, CorpusRun |
| delivery | Checkout, Commit, Landing, PushTrain, Shipment, PullRequest |
| release | Release, PublishingRun, PromotionRun, Registry, Package |
| ledger | Era, Seal, Audit, RehearsalRun |
| language | LanguageRun, KernelRun, ConformanceRun, SyntaxBootCache |
| launch | Launch, and the servers out of CorpusRun |
| agents | AgentRun |

The table is a starting point; the context-candidates query below settles it from the model's own
links.

**A bang is the only sign of a write.** `Name!` dispatches a command and `Name` asks a query,
always. `query` stops being needed and stays only as an old spelling while callers move.

**Who a command is for is declared, not guessed.** A command says `for: :person`, `:agent`, `:ci`
or `:record`. The world's `launcher` setting chooses which audiences a launcher lists, the MCP
door lists `:agent`, and `:record` (a run's own bookkeeping, the record-only verbs) is listed only
by `--all`.

**A family is one command with an argument** where the verbs are one act on different targets:
`project! what=`, `Build.build! target=`, `serve! what=`, `TestSuiteRun.run!` with `file=`,
`example=` or `since=`, `LanguageRun.move! word= to=`, `StyleRun.check! lang=` and
`StyleRun.fix! lang=`. Other verbs stay separate.

**Domain names carry no adapter words.** Section and context names never name a port or adapter.
The aggregate and verb names that do (`PullRequest`, `Commit`, `Checkout`, `PushTrain`,
`PullRequest.squash!`, `PushTrain.push!`, `Commit.commit!`, `Landing.merge!`, `Checkout.log`) are
renamed as their context moves.

## What the language needs first

1. **An aggregate declares where it came from** (`formerly "Hecks::PushTrain"`). The shape ledger
   accepts a move whose stored rows are unchanged without a hand-written edge, and the launcher
   resolves the old name, so the world's `names` stops listing moved aggregates by hand.
2. **A command declares its audience** (`for:`), replacing the `role == "System"` guess.
3. **A run is a declared kind** (`aggregate "StyleRun", kind: "Run"`). The `*Run` aggregates repeat
   one lifecycle (`requested` onward), one set of bookkeeping commands (`accept`, `perform`,
   `complete`, `fault`, `examine`) and one pair of queries (`*_outcome`, `*_faulted`); the kind
   declares them once and marks them `:record`.
4. **A query proposes contexts** (`Introspection.context_candidates`): aggregates no policy,
   reference or saga links are separate contexts in all but name.
5. **A check refuses adapter words in domain names.** The hecksagon names its ports and adapters;
   `model_check` refuses an aggregate, command or context spelled as one.
6. **A command's argument can choose the port operation.** `one_of:` closes an attribute's values;
   a family command also needs each value bound to its own operation in the hecksagon, so no
   hand-written dispatch stands behind `project!` or `build!`.
7. **A bang is required for a command.** Resolution stops falling back to a command when a name has
   no `!`.

## Plan

1. **Everyday list.** Add `everyday` to the world's `launcher` setting and have the projector list
   it first, inside a checkout too. Data only; no shape moves.
2. **Declared audience** (need 2), and the record-only verbs marked `:record`.
3. **The bang rule** (need 7), in three steps: a name without `!` that resolves to a command still
   runs and prints the `!` spelling as a warning; the repository, its hooks, `CLAUDE.md`, the push
   train's scripts and the clients move to `!`; then a name without `!` reaches only a query, and
   a command spelled without it is refused with the `!` spelling as a hint. `query` drops out of
   the listing and the docs.
4. **`formerly`** (need 1).
5. **Split `delivery` out first**: the cleanest seam, and it shows the full cost (the move, the
   context map's links for `Shipment`'s saga, the old names) on one context. Rename its
   adapter-word aggregates and verbs in the same move.
6. **The other contexts, one at a time**, using `context_candidates` (need 4) and the run kind
   (need 3), collapsing each context's families (need 6) as it moves.
7. **Retire the gem table's duplicates**: empty the world's `legacy` list once the launcher answers
   every form it covers.
8. **The adapter-word check** (need 5) joins the gate once the renames are done, so it starts
   green.

## Consequences

- Bare `hecks` fits on a screen, and a context's listing is short enough to read whole.
- Every moved aggregate is a shape change on the push train's database: each move mints an era
  there, through the `formerly` edge.
- Names in `CLAUDE.md`, hooks, scripts, clients and notes change twice over (the bang and the
  context). The warning step of the bang rule and `formerly`'s old-name resolution keep them
  working while they move.
- The bookkeeping verbs leave the listing but keep their `--help`.
