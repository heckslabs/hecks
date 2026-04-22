# CLAUDE_AUDIT.md

Audit of `.claude/` directories for staleness after today's renames and removals
(PR #245 `.hec` → domain-named files, PR #236 greeting churner removal, prior
`Winter` → `Miette` rename).

Date: 2026-04-21
Branch: `miette/claude-dir-audit`
Scope: inventory only — no `.claude/` edits in this PR.

## Files scanned

Both `.claude/` roots, every command/settings/hook/agent file:

- `/Users/christopheryoung/Projects/hecks/.claude/settings.json`
- `/Users/christopheryoung/Projects/hecks/.claude/settings.local.json`
- `/Users/christopheryoung/Projects/hecks/.claude/agents/security-reviewer.md`
- `/Users/christopheryoung/Projects/hecks/.claude/commands/bluebook.md`
- `/Users/christopheryoung/Projects/hecks/.claude/commands/glass.md`
- `/Users/christopheryoung/Projects/hecks/.claude/commands/navigate.md`
- `/Users/christopheryoung/Projects/hecks/.claude/commands/watchers.md`
- `/Users/christopheryoung/Projects/hecks/.claude/projects/-Users-christopheryoung-Projects-hecks/memory/feedback_watcher_response.md`
- `/Users/christopheryoung/Projects/hecks/hecks_conception/.claude/settings.local.json`
- `/Users/christopheryoung/Projects/hecks/hecks_conception/.claude/scheduled_tasks.lock` (runtime state, skipped)

Worktrees under `.claude/worktrees/` are ephemeral full-repo checkouts, not
config — explicitly out of scope.

## Findings

| # | File:line | Stale reference | Suggested fix |
|---|-----------|-----------------|---------------|
| 1 | `.claude/settings.local.json:15` | `ruby hecks_conception/boot_winter.rb --verbose` fallback path | `boot_winter.rb` does not exist; rename to `hecks_conception/boot_miette.sh` (or drop the Ruby fallback — the Rust `hecks-life boot` path is the primary and Ruby booter is gone). |
| 2 | `.claude/settings.json:36` | `ruby /Users/christopheryoung/Projects/hecks/hecks_conception/pulse.rb --dream` | `pulse.rb` does not exist. Closest equivalents: `hecks_conception/pulse_organs.sh` and `hecks_conception/daydream.sh`. Decide if dreaming on Stop is still desired; if yes, rewire to the shell script; if no, drop the hook. |
| 3 | `.claude/commands/glass.md:1` | "6,647 callable phrases across 80 domains" | Stale counts. Today: 480 bluebook files under `hecks_conception/`, 357 entries under `nursery/`. Replace with a dynamically described figure (e.g. "the full Hecks conception lexicon") or regenerate the numbers. |
| 4 | `.claude/commands/glass.md:14, 31, 68-70` | `hecks-life lexicon hecks_conception` subcommand | `lexicon` is not in the current `hecks-life --help`. The whole Glass command-palette flow is broken. Options: (a) implement a `lexicon` subcommand, (b) rewrite Glass to use `hecks-life list` + bluebook grep, (c) retire the command until the palette exists. |
| 5 | `.claude/commands/glass.md:38` | `grep -r "\"CommandName\"" hecks_conception --include="*.bluebook"` | Works today; keep. (Noted for completeness — this part still functions.) |
| 6 | `.claude/commands/glass.md:47` | `heki append hecks_conception/information/<Domain>.heki domain=<Domain> aggregate=<Aggregate> command=<Command> ...` | `.heki` files today are named after aggregates (e.g. `signal.heki`, `mood.heki`), not domains. Adjust the template to match current file-naming. |
| 7 | `.claude/commands/navigate.md:11` | `hecks-life lexicon hecks_conception` (pipeline) | Same as finding #4 — `lexicon` subcommand is gone. Rewrite or retire. |
| 8 | `.claude/commands/navigate.md:24` | `**Spring**: SpringRuntime, Greeting, FirstBreath` | `Greeting` domain removed in PR #236; no `spring*.bluebook` exists today. Drop the Spring group entirely, or replace with current core domains (Miette, Mind, Body, Hecksagon, Antibody, etc.). |
| 9 | `.claude/commands/navigate.md:22` | `**Miette**: Mind, MietteBody, SharedDream, SharedKnowledge, Vocabulary, Language, Voice` | `MietteBody`, `Vocabulary`, `Voice` aren't current bluebook names. Replace with actual aggregates (`miette`, `body`, `mindstream`, `shared_dream`, `shared_knowledge`, `tongue`, etc.) after a fresh inventory. |
| 10 | `.claude/commands/navigate.md:32` | `hecks-life lexicon hecks_conception 2>&1 \| grep "→.*DomainName::"` | Pipeline depends on `lexicon` output format that no longer exists. |
| 11 | `.claude/commands/navigate.md:55` | `heki append ... information/<Domain>.heki domain=<Domain> ...` | Same as finding #6 — heki files are aggregate-named, not domain-named. |
| 12 | `.claude/commands/watchers.md:7` | `ruby -I hecks_watchers/lib -r hecks_watchers -e 'HecksWatchers::PreCommit.new(project_root: Dir.pwd).call'` | `hecks_watchers/` component does not exist. Current watcher surface is `bin/watch-all` (wrapping the individual `bin/watch-*` scripts) and `bin/pre-commit`. Rewrite Step 1 to `bin/watch-all` or `bin/pre-commit`. |
| 13 | `.claude/commands/watchers.md:22` | `hecksties/lib/hecks/autoloads.rb` | Path moved. Current path is `lib/hecks/autoloads.rb`. |
| 14 | `.claude/agents/security-reviewer.md:17` | `hecksties/lib/hecks/extensions/auth.rb` | Path moved. Current path is `lib/hecks/extensions/auth.rb` (plus `lib/hecks/chapters/extensions/auth.rb`). |
| 15 | `.claude/agents/security-reviewer.md:17` | `runtime/gate_enforcer.rb` | Path moved. Current path is `lib/hecks/runtime/gate_enforcer.rb`. |
| 16 | `.claude/agents/security-reviewer.md:19` | `FilteredEventBus` | Still exists (`lib/hecks_multidomain/filtered_event_bus.rb`) — path is fine but worth linking for precision. |
| 17 | `.claude/commands/bluebook.md:31` | `ruby -Ilib -e "require 'hecks'; Hecks.boot('path/to/project')"` | The user's CLAUDE.md says "Always use Rust runtime — `hecks-life` for all bluebook parsing". Replace the Ruby verify step with `hecks-life parse <file>.bluebook` or `hecks-life validate <file>.bluebook`. |

Counts: **17 findings** across **6 files**. Estimated edits to resolve: **~15** (findings #5 and #16 are advisory / no action).

## Recommended follow-up PRs

Grouped by concern so each PR stays focused and reviewable.

### PR A — "fix: .claude/ hooks reference removed scripts" (critical; hooks fire on every session/stop)
- Finding #1 — `boot_winter.rb` fallback in `SessionStart` hook
- Finding #2 — `pulse.rb --dream` in `Stop` hook
- Rationale: these hooks run on every session — broken references fail silently (`|| true`) but waste the intended behavior.

### PR B — "fix: .claude/commands/{glass,navigate}.md rewrite for current surface" (largest)
- Findings #3, #4, #6, #7, #8, #9, #10, #11
- Decide first: either restore a `lexicon` subcommand in `hecks-life` (and keep the commands) or rewrite Glass/Navigate to use bluebook-file scanning. Big enough to warrant its own PR.

### PR C — "fix: .claude/commands/watchers.md + security-reviewer.md paths"
- Findings #12, #13, #14, #15
- Mechanical path-rename PR; small.

### PR D — "fix: .claude/commands/bluebook.md — use Rust runtime to verify"
- Finding #17
- Aligns with the "always use Rust runtime" rule in `hecks_conception/CLAUDE.md`.

### Optional PR E — add an invariant to `hecks_conception/status_coherence.sh`
- Add a check that every path referenced in `.claude/settings*.json` and `.claude/commands/*.md` actually exists in the repo. Would have caught findings #1, #2, #13, #14, #15 automatically.

## Not stale (verified in place)

- `bin/update-codebase-index` (SessionStart hook) — exists.
- `bin/read-watcher-log` (PostToolUse hook) — exists.
- `gem build hecks.gemspec` (Stop hook) — gemspec present.
- `hecks_life/target/release/hecks-life boot hecks_conception` — exists and is the primary SessionStart path.
- `.claude/projects/.../memory/feedback_watcher_response.md` — generic, no stale references.
- `hecks_conception/.claude/settings.local.json` — only sets permissions + statusline symlinks, no stale refs.
