# features_audit.py — cross-reference FEATURES.md against the codebase

`tools/features_audit.py` parses `FEATURES.md` into individual claims
and greps the codebase for evidence of each one. It reports three
buckets per claim:

- **verified** — at least one extracted identifier (class name, method,
  DSL keyword, symbol) was found in the searched source trees.
- **missing** — identifiers exist in the claim but none of them were
  found anywhere. This is drift: the documentation asserts something
  that isn't implemented (or was renamed).
- **unverifiable** — the claim is pure prose, no code-like identifiers
  to grep on. Can't be confirmed or refuted automatically.

## What it searches

- `lib/` (Ruby implementation)
- `hecks_life/src/` (Rust implementation)
- `hecks_conception/aggregates/` and `hecks_conception/capabilities/` (Bluebook)
- `spec/` (tests)
- `examples/` (generated sample apps, often carry real method names)
- `bin/` (CLI entry points and watcher scripts)
- `.claude/` (hook configs and slash commands)

Docs directories are intentionally not searched — evidence from the
docs themselves would be circular.

## Quick start

```bash
# summary + per-section counts
python3 tools/features_audit.py

# list every missing claim with its extracted identifiers
python3 tools/features_audit.py --missing

# filter to a single section
python3 tools/features_audit.py --section "Chapter CLI"

# machine-readable output
python3 tools/features_audit.py --json
```

## How identifiers are extracted

The tool trusts shapes strong enough not to match English prose:

- `` `backticked` `` code (always trusted, even single-word tokens
  like `emits` or `lifecycle`)
- PascalCase with at least two humps (`CreatePizza`, `EventBus`)
- Namespaced (`Hecks::Chapters::Binding`)
- Dotted (`Hecks.configure`, `workbench.chapter`)
- `:symbol` names of length ≥ 3

Placeholder patterns common in prose are stripped: `<Some>Domain.x`,
`model.foo?`, `handle.build`, and `.md` link targets.

For class-method tokens like `Foo.bar`, if the literal `Foo.bar` isn't
found anywhere but `Foo` is, the tool looks for `def self.bar` in the
same trees. For lowercase-head tokens (`domain.flows`) it falls back
to `def flows`.

## Current state

As of the initial audit:

```
702 claims
  verified     427  (60.8%)
  missing        0  ( 0.0%)
  unverifiable 275  (39.2%)
```

The audit starts with **zero missing**. Running the tool after a
FEATURES.md update is the antibody — if the count goes above zero,
something was claimed without evidence.

## Known limitations

- Identifiers that exist only as dynamically generated methods
  (e.g. `<domain>.start_<saga>`) can look like drift if the feature
  doc doesn't also mention the generating machinery.
- High "unverifiable" count (~40%) reflects that many claims are
  descriptions of behavior rather than API surface — "Domain services
  orchestrate multiple commands" has no identifier to grep on. This is
  expected, not a defect.
- Not wired into CI yet. The natural next step is a GitHub Action
  that fails on non-zero `missing`.
