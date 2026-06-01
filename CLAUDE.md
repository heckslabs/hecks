# CLAUDE.md

## Rules

- **No Co-Authored-By** — never add Co-Authored-By lines to commit messages
- **No file over 200 lines of code** — doc comment headers don't count toward this limit; extract modules/classes by concern when approaching it
- **Tests must run under 1 second** — enforced by pre-commit hook
- **Every lib file has a doc comment header** — class name, purpose, usage example
- **Stage specifically** — never `git add -A`, always name files

## Before every commit

- Documentation is the bluebook — no separate prose docs (2026-05-17).
1. Run specs — all must pass (speed enforced by hook)
2. Check file sizes — `find lib -name "*.rb" -exec wc -l {} + | sort -rn | head -5`
3. Smoke test — `ruby -Iruby examples/pizzas/pizzas.rb`

## Conventions

- Memory adapters for tests — fast and isolated
- CalVer versioning (YYYY.MM.DD.N)
- Aggregates are pure domain objects — no persistence logic
- CLI commands are each their own file under `lib/hecks/cli/commands/`
- Module grouping: parent file with `.bind`, children in subdirectory
- `Hecks.boot(__dir__)` for apps, `Hecks.configure` for Rails
- Generators show a diff when a target file already exists (never silently overwrite)

## Tonight's locked conventions (2026-05-12)

- **Four bluebook-first principles**:
  1. It just works — bluebook is the contract; runtime defaults to memory; the dispatch IS the act
  2. Wiring is override, not substrate — adapters change behaviour, they don't fix broken bluebooks
  3. Domain doesn't know it hibernates — time is continuous from the inside; persistence is the runtime's problem
  4. Domain composes the tool call; the adapter runs it — pure composition meets pure execution at the bus boundary
- **Self-ref dispatch** — `reference_to(AggName)` accepts both `snake_case(AggName)=<id>` AND the universal `id=<value>` fallback (added tonight via the universal-id sidequest)
- **List shape is explicit** — `attribute :foos, Foo` is SCALAR. Lists require `list_of(X)`. The auto-list heuristic is retired in both the Ruby and Rust parsers
- **VO placement** — `value_object` declarations live INSIDE each aggregate. Duplication across aggregates is fine; bluebook-file-top-level VOs are forbidden (macrophage check `bluebook_top_level_value_object`, i555)
- **Macrophage rename** — `enforcer` is now `macrophage` (i531/i553). `storehouse enforce-edit` still works as a deprecation-warning alias
- **Tools.bluebook** — Miette's first-class tool invocations dispatch through the bus as `ShellTool.Bash`, `FileTool.Read` / `FileTool.Edit` / `FileTool.Update`, `SearchTool.Grep` / `SearchTool.Glob`, `WebTool.WebFetch` / `WebTool.WebSearch` ; outcomes cascade into `Cascade.RecordResult`. Restructured 2026-05-12 from a flat `Tools` aggregate into five category aggregates.

## Tonight's locked conventions (2026-05-13)

- **`storehouse__dispatch` is the universal door** — `storehouse__dispatch_command` renamed to `storehouse__dispatch`. Any bluebook command on any aggregates root flows through it. No per-command MCP tool wrappers ; the bluebook IS the contract
- **9 hand-registered Tools.* sugar wrappers retired** — `storehouse__bash`, `_read`, `_edit`, `_update`, `_grep`, `_glob`, `_web_fetch`, `_web_search`, `_record_result` are gone from the MCP surface. Use `storehouse__dispatch` with the FQN verb instead (e.g. `command: "Tools::ShellTool.Bash"`)
- **`storehouse__list` retired** — use `storehouse__catalog` (full IR JSON for a bluebook) and `storehouse__describe_aggregate` (one aggregate's IR). MCP surface is now 10 tools.
- **New `storehouse` CLI subcommands** — `describe <bluebook> <aggregate>`, `query <root> <Domain::Aggregate.snake_case> k=v ...`, `state <root> <aggregate> <id>`
- **FQN required at runtime** — `Domain::Aggregate.Command` for commands, `Domain::Aggregate.snake_case` for queries. Short-form `Tools.Bash` is rejected
- **Macrophage hook live on PostToolUse** — `bin/macrophage-hook` wired alongside `read-watcher-log`. Fresh complaints surface as `hookSpecificOutput.additionalContext`. `[enforcer]` stderr labels are now `[macrophage]` ; complaint text reads "The macrophage expected"

## Sprint 14 actor model observability (2026-05-31)

- **`storehouse mailboxes` debug subcommand** — inspect the actor-model surface from the CLI. Three verbs : `mailboxes list` (every active mailbox with status/queue_depth/events_processed), `mailboxes show <type> <id>` (per-mailbox detail), `mailboxes poisoned` (filter to poisoned). All accept `--json` for tooling consumers and `--fixture` to render against a deterministic 3-mailbox demo (idle/running/poisoned) — useful before the live runtime wires a process-wide `Mailboxes` table through the bus. The conceptual *actor* stays a bluebook concept (every aggregate is an actor) ; this CLI observes runtime *mailbox* state. The HashMap IS the lookup table — no separate registry concept.
- **Mailbox getters** — `queue_depth()`, `status()`, `events_processed_count()`, `last_error()` on `runtime::actor::Mailbox` ; `Mailboxes::snapshot()` returns `Vec<MailboxSummary>` for the CLI to render without touching the Mailboxes-table's mutexes.
