# Security

hecks is a research language, not a hardened production dependency —
that's the honest framing, not a hedge, and it applies here too. It
still runs real code against real state (the Postgres/Sqlite/Heki
adapters, the Lambda dispatcher, the OAuth2/Google-ID-token
authentication adapter, generated SAM/deploy artifacts) on behalf of
whatever project embeds it, so a real vulnerability report is welcome
and will be taken seriously.

## Reporting a vulnerability

**Preferred: GitHub Security Advisories.** Use this repository's
["Report a vulnerability"](https://github.com/heckslabs/hecks/security/advisories/new)
form (under the Security tab) to open a private advisory. It reaches
the maintainer without ever becoming a public issue, and keeps
discussion, a fix, and the disclosure timeline attached to one thread.

**Alternative: email.**
chris@embryonaut.ai. If you'd rather not use GitHub at all, use this
instead; expect slower turnaround than the advisory form since it
depends on the address actually being watched.

Please do not open a public issue for a suspected vulnerability.

### What to include

- The `.bluebook`/`.hecksagon`/`.world` snippet that reproduces it, or
  the smallest one you can build that still does — the same shape
  `spec/corpus/` and `bin/fuzz`'s own shrinker favor: small enough to
  actually read.
- Which adapter or port is involved, if any (`Postgres`, `PostgresEra`,
  `Heki`, the Lambda dispatcher, an authentication adapter) — several
  of these touch real credentials, real SQL, or a real cloud deploy,
  and the report needs enough context to reproduce, not just describe.
- Ruby version, hecks gem version (or commit SHA if running off a
  checkout), and whether the issue is Ruby-only or reproduces through
  the Rust runtime under `rust/` as well.
- What you expected the runtime to refuse, and what it did instead.

### What to expect

An acknowledgment within a few days. This is a small project without a
dedicated security team — response time depends on the maintainer's
own availability, not a formal SLA. Once a fix is ready, coordinated
disclosure is the default: the reporter is credited (unless they'd
rather not be) once a patched version is out, not before.

## Areas worth extra scrutiny

Named here because they are the parts of this codebase where "wrong"
means more than a bad refusal message:

- **`PostgresEra`'s `compute` rule** — a raw SQL expression, evaluated
  inside Postgres during a schema-evolution translation. It is meant to
  run against trusted, project-authored translation files; treat any
  path that lets untrusted input reach a `compute` string as a real
  finding.
- **`bin/project_deploy`'s generated artifacts** — SAM templates,
  `samconfig.toml`, bastion config. These compose connection strings
  from AWS-managed secrets and CloudFormation dynamic references
  specifically so nothing is typed in plaintext; a generator change
  that regresses that is a security bug, not a style one.
- **The OAuth2 / Google-ID-token authentication adapter** and the
  **Lambda remote-dispatcher adapter** (`lib/hecks/adapters/driven/`) —
  the two adapters that reach outside the process boundary by design.
- **The expression grammar's Admit gate** (`lib/hecks/grammar/
  expression_operators.json`) — a `given`/invariant predicate is parsed
  and stored as canonical text, not held as a closure; anything that
  lets an admitted operator's rendering diverge from what actually
  evaluates is worth reporting even without an obvious exploit in mind.
- **Argument-gate coverage on every dispatch path.** `CommandInterpreter`
  (aggregate commands) and `PortOperationInterpreter` both refuse
  unknown/absent arguments; `EntityInterpreter` (a piece an aggregate
  holds — `Account.LedgerEntry.Reverse`, say) silently ran with no such
  gate at all until 2026-08-27, on a comment claiming it "inherited" a
  check that nothing on its dispatch path ever actually ran — a bogus
  argument was accepted, and an omitted declared one silently nil'd the
  field it should have set. Fixed, but the class is worth naming here:
  any new dispatch path (a future entity-chain hop, a new interpreter)
  needs its own explicit `refuse_unknown_arguments`/
  `refuse_absent_arguments` step — nothing enforces that structurally,
  and this is exactly the kind of gap a full test suite passing green
  does not catch, because the missing check has no positive assertion
  to fail.

## Supported versions

Pre-1.0 (currently 0.3.0 per `lib/hecks/version.rb`): no parallel
maintenance branches. Fixes land on the latest release; there is no
commitment yet to backport a security fix to an older tag.
