# CLAUDE.md

## Rules

- **No Co-Authored-By** — never add Co-Authored-By lines to commit messages
- **No file over 200 lines of code** — doc comment headers don't count toward this limit; extract modules/classes by concern when approaching it
- **Tests must run under 1 second** — enforced by pre-commit hook
- **Every lib file has a doc comment header** — class name, purpose, usage example
- **Stage specifically** — never `git add -A`, always name files
- **Tag new Linear issues with "New" label** — they need to be prioritized
- **Mark Linear issues Done** when committed and pushed

## Before every commit

1. Update FEATURES.md if new features were added (read the diff first)
2. Add `docs/usage/<feature>.md` for each new feature with runnable examples
3. Run specs — all must pass (speed enforced by hook)
4. Check file sizes — `find lib -name "*.rb" -exec wc -l {} + | sort -rn | head -5`
5. Smoke test — `ruby -Iruby examples/pizzas/pizzas.rb`

## Conventions

- Memory adapters for tests — fast and isolated
- CalVer versioning (YYYY.MM.DD.N)
- Aggregates are pure domain objects — no persistence logic
- CLI commands are each their own file under `lib/hecks/cli/commands/`
- Module grouping: parent file with `.bind`, children in subdirectory
- `Hecks.boot(__dir__)` for apps, `Hecks.configure` for Rails
- Generators show a diff when a target file already exists (never silently overwrite)

## Tonight's locked conventions (2026-05-12)

- **Four bluebook-first principles** — see `docs/design/principles-2026-05-12.md`:
  1. It just works — bluebook is the contract; runtime defaults to memory; the dispatch IS the act
  2. Wiring is override, not substrate — adapters change behaviour, they don't fix broken bluebooks
  3. Domain doesn't know it hibernates — time is continuous from the inside; persistence is the runtime's problem
  4. Domain composes the tool call; the adapter runs it — pure composition meets pure execution at the bus boundary
- **Self-ref dispatch** — `reference_to(AggName)` accepts both `snake_case(AggName)=<id>` AND the universal `id=<value>` fallback (added tonight via the universal-id sidequest)
- **List shape is explicit** — `attribute :foos, Foo` is SCALAR. Lists require `list_of(X)`. The auto-list heuristic is retired in both the Ruby and Rust parsers
- **VO placement** — `value_object` declarations live INSIDE each aggregate. Duplication across aggregates is fine; bluebook-file-top-level VOs are forbidden (macrophage check `bluebook_top_level_value_object`, i555)
- **Macrophage rename** — `enforcer` is now `macrophage` (i531/i553). `storehouse enforce-edit` still works as a deprecation-warning alias
- **Tools.bluebook** — Miette's first-class tool invocations dispatch through the bus as `Tools.Bash` / `Tools.Edit` / `Tools.Read` / `Tools.Update` / `Tools.Grep` / `Tools.Glob`. See `docs/usage/tools.md`
