# hecks_watcher_agent

Autonomous agent that reads watcher logs and creates PRs to fix issues.

## CLI Usage

```bash
hecks fix-watchers
```

Reads `tmp/watcher.log`, parses issues, creates a branch, applies fixes, and opens a PR.

## Auto-trigger

The `bin/post-commit` hook automatically launches the agent in the background when watchers report issues during a commit.

## How Fixes Work

### Pure Ruby (fast, deterministic)

- **Autoloads** — adds missing entries to `hecksties/lib/hecks/autoloads.rb`
- **Spec Coverage** — generates skeleton `_spec.rb` files for new lib files

### Claude Code (complex fixes)

- **File Size** — delegates to `claude` CLI to extract modules and reduce file length
- **Doc Reminders** — delegates to `claude` CLI to update FEATURES.md and changelogs

### Skipped (filed for follow-up)

- **Cross Require** — needs architectural decision, not auto-fixable; logged as an inbox card for triage

## Example Output

```
Found 3 watcher issue(s):
  [autoloads] Generator (hecks_domain/lib/hecks/generator.rb)
  [spec_coverage] hecks_domain/lib/hecks/generator.rb → expected hecks_domain/spec/generator_spec.rb
  [file_size] ui_generator.rb: 192 lines (limit: 200)
  Fixed: autoload Generator
  Fixed: skeleton spec for Generator
  Delegating to Claude Code: ui_generator.rb: 192 lines (limit: 200)
```
