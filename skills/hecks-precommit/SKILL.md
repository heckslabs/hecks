---
name: hecks-precommit
description: 'Pre-commit checklist for the Hecks framework. Use before every commit to ensure FEATURES.md is updated, usage docs exist, specs pass under 1 second, file sizes are within limits, and the smoke test runs.'
license: MIT
metadata:
  author: hecks
  version: "1.0.0"
---

# Hecks Pre-Commit Checklist

Run this checklist before every commit in the Hecks framework. All steps are mandatory.

## Step 1: Update FEATURES.md

If the diff includes new features, update `FEATURES.md` at the project root.

- Read the staged diff first (`git diff --cached`)
- Only update if new user-visible capabilities were added
- Match the existing bullet-point style and section grouping
- Do not rewrite existing entries — append to the appropriate section

## Step 2: Usage Documentation

For each new feature, ensure a file exists at `docs/usage/<feature>.md`.

- Include a runnable code example (not pseudocode)
- Show expected output
- Keep it concise — one page per feature

## Step 3: Run Specs

```bash
bundle exec rspec
```

- All specs must pass
- Total runtime must be under 1 second (enforced by pre-commit hook)
- If specs fail, fix them before committing
- Tests use memory adapters — no external dependencies

## Step 4: Check File Sizes

```bash
find lib -name "*.rb" -exec wc -l {} + | sort -rn | head -5
```

- No lib file may exceed 200 lines of code
- Doc comment headers (the block at the top of each file) do not count toward this limit
- If a file is too long, extract modules/classes by concern

## Step 5: Smoke Test

```bash
ruby -Ilib examples/pizzas/pizzas.rb
```

- Must run without errors
- Verifies that the core domain pipeline works end-to-end
- If it fails, something fundamental is broken — fix before committing

## Commit Rules

- Stage files specifically by name — never use `git add -A` or `git add .`
- No Co-Authored-By lines in commit messages
- Follow the existing commit message style (check `git log --oneline -5`)
