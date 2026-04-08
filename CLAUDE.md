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
5. Smoke test — `ruby -Ilib examples/pizzas/pizzas.rb`

## Conventions

- Memory adapters for tests — fast and isolated
- CalVer versioning (YYYY.MM.DD.N)
- Aggregates are pure domain objects — no persistence logic
- CLI commands are each their own file under `lib/hecks/cli/commands/`
- Module grouping: parent file with `.bind`, children in subdirectory
- `Hecks.boot(__dir__)` for apps, `Hecks.configure` for Rails
- Generators show a diff when a target file already exists (never silently overwrite)
