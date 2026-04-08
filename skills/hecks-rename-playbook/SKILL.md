---
name: hecks-rename-playbook
description: 'Playbook for large renames and restructures in the Hecks framework. Use when renaming modules, classes, directories, or DSL keywords across the codebase. Covers the full checklist: find references, update requires, update tests, update examples, update docs.'
license: MIT
metadata:
  author: hecks
  version: "1.0.0"
---

# Hecks Rename & Restructure Playbook

Hecks frequently does large renames (e.g., ports → gates, console → workshop, session → workbench → workshop). This playbook ensures nothing is missed.

## Principles

- **Don't hesitate on big renames.** There are no users yet, so there's no backward compatibility burden. Break APIs freely.
- **No backward compat shims.** Don't add aliases, re-exports, or deprecation wrappers. Just rename and delete the old thing.
- **Never use sed/perl for bulk Ruby renames.** Use the Edit tool or precise Ruby scripts. Bulk regex replacements create subtle breakage.
- **Lock down the new name before starting.** Decide the API name first. Don't rename iteratively.

## Checklist

### 1. Inventory

Before changing anything, find every reference to the old name:

```bash
# Find in Ruby files
grep -r "OldName" lib/ spec/ examples/ --include="*.rb" -l

# Find in docs
grep -r "old_name\|OldName" docs/ FEATURES.md README.md CHANGELOG.md -l

# Find in config/tooling
grep -r "old_name" .claude/ bin/ Rakefile Gemfile *.gemspec -l
```

Record the full list. This is your work tracker.

### 2. Rename Files and Directories

Start with the filesystem structure:

- Rename directories (e.g., `lib/hecks_console/` → `lib/hecks_workshop/`)
- Rename files (e.g., `console.rb` → `workshop.rb`)
- Update gemspec filenames if applicable

### 3. Update Ruby Source

For each file in the inventory:

- Module/class declarations: `module OldName` → `module NewName`
- Require statements: `require "old_name"` → `require "new_name"`
- Require_relative statements
- Class references: `OldName::Thing` → `NewName::Thing`
- Method names: `def old_name` → `def new_name`
- String references: `"old_name"` used in DSL or registry
- Symbol references: `:old_name` used in registries or configs

### 4. Update Autoloads

If the project uses autoload registries (`autoloads.rb` files), update all entries.

### 5. Update Tests

- Spec file paths: `spec/old_name/` → `spec/new_name/`
- Spec descriptions: `describe OldName` → `describe NewName`
- Spec require lines
- Shared context and helper references

### 6. Update Examples

Every example app in `examples/` that references the old name:

- `require` lines
- Method calls
- Configuration blocks
- File paths in comments

### 7. Update Documentation

- `FEATURES.md` — find and replace all mentions
- `README.md`
- `docs/usage/*.md`
- `CHANGELOG.md` if it exists
- Inline comments in code

### 8. Update Tooling

- `CLAUDE.md` conventions section
- `.claude/` settings and commands
- `bin/` scripts
- Gemfile and gemspec files
- Rakefile

### 9. Verify

```bash
# Run specs
bundle exec rspec

# Smoke test
ruby -Ilib examples/pizzas/pizzas.rb

# Check for orphaned references
grep -r "OldName\|old_name" lib/ spec/ examples/ docs/
```

The grep in step 9 should return zero results. If anything remains, fix it.

### 10. Commit

One commit for the entire rename. Don't split across multiple commits — it makes bisecting harder and the intermediate states are broken anyway.

## Past Renames (for Pattern Reference)

| Old | New | Scope |
|-----|-----|-------|
| `ports` | `gates` | DSL keyword, class names, specs, docs |
| `console` / `web_console` | `workshop` / `web_workshop` | Gem name, module, CLI command, file paths |
| `hecks_session` | `hecks_workbench` → `hecks_workshop` | Gem, module, REPL command |
| `name` parameter | removed | `Hecks.hecksagon` API change |
