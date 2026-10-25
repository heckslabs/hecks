# An environment variable is a one-off override or a secret

**Status:** Proposed. Date: 2026-10-25.

## Context

Hecks reads many environment variables. Most exist because a thing had no default
location or no default name, not because a person needs to vary it per run. Each one is
a hidden input: it is absent from the bluebook, the hecksagon and the world, and a copy
works or fails depending on the shell that launched it.

## Decision

1. **If it describes what something is connected to, it is declared** in a world or a
   hecksagon (the same split bluebook and hecksagon already make).
2. **If it is derivable from where the copy lives, it is derived.** Nobody declares it.
3. **Only a one-off override or a secret is an environment variable.** A secret is read
   from 1Password and never written to config.
4. **Precedence:** an explicit variable, then the world, then the derived default.
5. **`hecks config` prints each resolved value and which of the three supplied it**, so
   derivation is never hidden.
6. **Retirement:** a variable outside the kept list below logs a deprecation warning for
   one release, then is no longer read.

## Classification

**Derived (retire the variable):**
`HECKS_RUST_DIR`, `CARGO_TARGET_DIR` (from the copy's root and the shared cache, as
`TargetDir` already does); `HECKS_LIB` (the Gemfile or vendored hecks says which);
`HECKS_TRAIN_HOME` (the launcher lives at `~/.claude/hecks-train`);
`EMBRYONAUT_BLUEBOOKS_SRC` (a sibling checkout, or the registry URL in project config);
`HECKS_CACHE_DIR` and the other cache locations (from the shared cache root).

**Declared in the world (retire the variable):**
`HECKS_DATABASE` (the copy's `environments/local.world`, else a database named for the
domain), `HECKS_SCHEMA`, `HECKS_PROJECT_ENVIRONMENT`, `DATABASE_URL` and `POSTGRES_URL`
for era tooling, `HECKS_DOMAIN`, `HECKS_SERVICE_URL`.

**Declared as settings (move into the hecksagon or project config, with defaults):**
analytics hosts and ids, smoke settings (`SMOKE_CONFIG`), `SETTLE_TIMEOUT_SECS`,
`SITE_URL`, `DOMAIN_NAME`, the OAuth client ids and redirect URIs.

**Kept as per-run switches (documented overrides):**
`HECKS_ENVIRONMENT` (memory for specs), `CI`, `GOLDEN=rewrite`, `HECKS_PRE_PUSH_GATE`,
`HECKS_PUSH_TRAIN=off`, `HECKS_PREBUILT=off`, `EXISTING_TAG` (rollback), and the seed and
iteration dials of the fuzzers. `HECKS_FUZZ_SCHEMA` stays only for pool children, and
defaults to one per process.

**Secrets (stay variables, sourced from 1Password):**
the analytics reader password, `API_TOKEN`, `AUTH_SECRET`, `SESSION_SECRET*`,
`PAYMENT_WEBHOOK_SECRET`, `GOOGLE_CLIENT_SECRET`, `PGPASSWORD`. A world file names the
1Password item, never the value.

## Order of work

1. Derived variables: no schema change.
2. World-declared variables: `environments/*.world` becomes the one place a copy says
   what it connects to.
3. Declared settings: needs a decision on where in the hecksagon they are written.

## Consequences

- A fresh copy runs with no shell setup.
- A variable that is still read but not listed above is a finding the gate can report.
- `HECKS_DATABASE` set globally in a shell, which once let dev checkouts boot newer
  bluebooks against the records database, stops being possible by construction.
