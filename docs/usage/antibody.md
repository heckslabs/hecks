# Antibody: no new non-bluebook code

`bin/antibody-check` fails a commit or PR that adds **or modifies** any
file written in a language that isn't part of the Hecks source vocabulary.

## The vocabulary

Five file types. That's all.

| Extension | What it declares |
|---|---|
| `.bluebook` | domains, aggregates, commands, events, policies |
| `.hecksagon` | adapters — shell-out, git, fs, network, DB |
| `.fixtures` | data (replaces yaml/json config) |
| `.behaviors` | behavioral tests |
| `.world` | world / environment declarations |

`hecks-life` parses and dispatches all five natively. There is no
compile step and there are no generated artifacts.

## Why

No Ruby. No Rust. No Python. No shell. Everything the system does is
expressed in the five DSLs above. Bluebook is Turing complete and more
readable than anything else in the repo.

Every file *not* in the five DSLs is a gap — either the concept should
be re-expressed in one of them, or the runtime needs to grow so it can.

The terminal state: `bin/` contains `.bluebook` files with
`#!/usr/bin/env hecks-life run` shebangs. `lib/` shrinks toward zero.
Shell-out, git calls, filesystem, network — all `.hecksagon` adapters.

## What the check does

Diffs the current branch against a base (default `origin/main`) and
lists every **added or modified** file that matches a flagged extension
or shebang. Running `bin/antibody-check` by itself is safe — it reads,
doesn't write.

```
⚠ antibody: 2 non-bluebook file(s) touched
    lib/hecks/runtime/something.rb
    config/routes.yml

  Bluebook is the source AND the thing that runs.
  ...
```

Extensionless binaries are classified by shebang (`ruby`, `bash`, `sh`,
`python`, `node`). Unknown shebangs fall through as non-code.

## Where it runs

- **Pre-commit hook (`bin/git-hooks/pre-commit`, Gate 5):** blocking.
  Catches violations before they become commits. Bypass in an emergency
  with `ANTIBODY_SKIP=1 git commit ...` — the bypass itself is a smell.
- **CI (`.github/workflows/antibody.yml`):** blocking. Second layer —
  catches anything that slipped past a missing or stale local hook.
  PR runs emit GitHub annotations so flagged files surface on the diff.

## Exemption

When the antibody fires, you have two choices: **fix it now** (rewrite
the concept as one of the five DSLs) or **exempt this specific change**
with a concrete reason.

Exemptions are **case-by-case.** There are no pre-approved categories,
no standing allowlists, no named carve-outs. Each exemption justifies
*one specific change* — the next PR that touches the same file makes
its own case from scratch.

Put `[antibody-exempt: <reason>]` in any commit message on the branch.
Good reasons name the concrete gap and how it'll close:

```
fix: patch saga retry logic

[antibody-exempt: patching lib/hecks/runtime/saga_retry.rb before it
 ports to a Saga bluebook; port tracked in i29]
```

```
feat: add CI job for parity suite

[antibody-exempt: GitHub Actions YAML — will move to .hecksagon once
 a CI-adapter shape exists]
```

Thin reasons (`runtime`, `temporary`, `bootstrap`) are the smell the
antibody is trying to prevent. If you can't name the gap, that's a
signal the change should wait for a bluebook instead.

## Follow-up path

The antibody is transitional. The real win is:

1. `hecks-life run <file.bluebook>` as a stable entry point.
2. `#!/usr/bin/env hecks-life run` shebang so bluebooks are directly
   executable scripts.
3. `.hecksagon` adapters declare shell-out / git / fs / network /
   DB surfaces in the same native DSL.
4. `bin/*.bluebook` files replace every existing `bin/*` wrapper.
5. `lib/` shrinks toward zero as capabilities move into `.bluebook`
   and `.hecksagon`.
6. Eventually `hecks_life/` too — the runtime describes itself in the
   same five DSLs.

Once that's in place, the antibody stops counting exemptions and starts
counting how many non-five-DSL files are left in the repo. Zero is the
target. No Ruby, no Rust, no Python, no shell.

### The antibody itself is a gap

`bin/antibody-check` is Ruby — itself covered by `runtime:ruby` /
`bootstrap:git-hooks`. The proper shape is a `hecks-life check-antibody`
subcommand alongside `check-lifecycle` and `check-io`, driven by a
`.bluebook` + `.hecksagon` pair. That port is tracked separately; until
it lands, the Ruby script is the working form.
