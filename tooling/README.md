# tooling/

Here live the small instruments the framework uses on itself — the features audit, the git hooks, the verify command. Not part of the language, not part of an integration ; the workshop's own tools, *comme les outils sur l'établi* — kept separate from the work so neither gets in the other's way.

## What lives here

| File / dir              | What it is |
|------------------------|---|
| `git-hooks/`           | The tracked git hooks : `pre-commit` (parity gate, lifecycle validator, antibody surface) and `commit-msg` (antibody enforcement — requires bluebook-only files or explicit exemption markers in commit messages) |
| `install-hooks`        | One-shot installer that copies `git-hooks/*` into `.git/hooks/`. Run after clone, or whenever a hook changes |
| `verify`               | Wrapper around `Hecks::Validate.run` — the bluebook self-verification that boots the same way the server boots, then validates every project it discovers |
| `features_audit.rb`    | Parses `FEATURES.md` into individual claims and verifies each is exercised somewhere in the test corpus. The honesty filter for `FEATURES.md` |

## Installing hooks

```sh
tooling/install-hooks
```

Copies every file in `tooling/git-hooks/` into `.git/hooks/`, marking each executable. Idempotent — re-run whenever a hook is updated.

## Verifying

```sh
tooling/verify                # validate everything ; text output
tooling/verify --format json  # machine-readable
```

Discovers every project under the working tree and validates them in turn. Same exit-code contract as the live boot : `0` on clean, `1` if any errors surface.

## Auditing FEATURES.md

```sh
ruby tooling/features_audit.rb              # summary report
ruby tooling/features_audit.rb --missing    # list claims not exercised by tests
ruby tooling/features_audit.rb --section "Attributes"  # filter to one section
ruby tooling/features_audit.rb --json       # machine-readable
```

Each line in `FEATURES.md` becomes a claim ; the audit asks of each : *is some identifier in this claim exercised by a test artefact ?* Claims that aren't move into the *Aspirational* section. The two-section split keeps `FEATURES.md` honest.

## Why these aren't in `bin/`

`bin/` holds **user-facing executables** — the `hecks` gem CLI, helpers for building gems, generating examples, running behaviours. Things a user installs and runs.

`tooling/` holds **dev-process scripts** — instruments the framework uses on itself. Things a contributor runs while working on `hecks`. The separation isn't enforced by anything ; it's a courtesy to readers who want to understand what kind of file each one is at a glance.

## See also

- inbox `i118` — the framework reshape arc that put this directory at the top level
- inbox `i124` — the Round 1 story that lifted these specific files (successor to lost `i127`)
