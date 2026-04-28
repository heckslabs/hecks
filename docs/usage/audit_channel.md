# Audit channel — every heki write declares its provenance

Every write to a `.heki` store must declare *why* it's happening. This is
Option C (the dispatch-only-mutation discipline): the runtime's `WriteContext`
type forces every caller to pick one of two paths, and out-of-band writes
are visible in the audit log.

## The two contexts

```rust
pub enum WriteContext<'a> {
    Dispatch { aggregate: &'a str, command: &'a str },
    OutOfBand { reason: &'a str },
}
```

- **`Dispatch`** — the write is the result of a domain command running through
  the runtime's dispatch loop. The aggregate and command names are recorded.
  This is the right path for production code: every state change is the
  observable effect of an explicit domain action.

- **`OutOfBand`** — the write bypasses dispatch. The caller must supply a
  one-line reason. Used for test setup, migrations, bootstrap seeds, or
  legitimate adapters that the runtime can't yet dispatch from.

The CLI mirrors this:

```sh
# dispatched (preferred):
hecks-life aggregates/ Item.Add ref=i112 priority=high body="..."

# out-of-band (requires --reason):
hecks-life heki append information/inbox.heki --reason "test setup" \
  ref=i112 priority=high body="..."
```

If you try to use `heki append` / `upsert` / `delete` / `mark` without a
`--reason`, the CLI rejects the call:

```
hecks-life heki append requires --reason "<why>" — direct heki
writes bypass the dispatch path. Use a domain command instead, or
pass --reason to mark this as an out-of-band write.
```

## What you see in the audit log

`OutOfBand` writes always log to stderr; `Dispatch` writes log only when
`HECKS_HEKI_AUDIT=1` is set. The format is parseable:

```
[heki:append]  dispatch:Item.Add → information/inbox.heki
[heki:upsert]  out-of-band:test setup → information/exempt_registry.heki
[heki:append]  out-of-band:initial subcommand catalog seed → information/subcommand.heki
```

Greppable by op (`append` / `upsert` / `delete`) or by tag prefix
(`dispatch:` / `out-of-band:`). The dashboard in `hecks-life status`
can surface direct-write rates as a discipline metric.

## The breadcrumb

Every dispatched command writes its name + a unix timestamp to
`<data_dir>/.last_dispatch`:

```
Item.Add
1761650140
```

The statusline reads that file and renders `🛠️ Item.Add` when the
breadcrumb is fresh (under 30 seconds old). It surfaces what *just*
happened — useful for spotting daemon-vs-human dispatches at a glance.

Only the **top-level** dispatch writes the breadcrumb. Cascade leaves
(commands fired by policies subscribed to other commands' events) don't
overwrite the breadcrumb, so what you see is the entry point Miette
chose, not the deepest cascade leaf.

## `HECKS_DAEMON=1` — daemon traffic stays internal

Body daemons (mindstream, heart, breath, pulse_organs, consolidate, …)
fire dozens of dispatches per second. Writing every one of them to
`.last_dispatch` would drown out human-driven actions in the statusline.

Daemons set `HECKS_DAEMON=1` in their environment; the runtime reads it
and skips the breadcrumb write when set. The dispatched events still
fire normally, the audit log still records them, repositories still
save — only the breadcrumb file is suppressed.

```sh
# In boot_miette.sh and mindstream.sh:
export HECKS_DAEMON=1
```

So the statusline shows the most recent **interactive** dispatch:
`🛠️ Item.Add`, `🛠️ Antibody.RegisterExemptions`, `🛠️ Disposition.Establish`.
Body cycles tick beneath without cluttering the surface.

## Why this matters

Before Option C, direct `heki append` calls were indistinguishable from
dispatched writes. Reach-pasts (shell scripts that bypassed bluebook
commands to write heki directly) accumulated invisibly. The audit
channel makes that cost legible:

> A 38-record catalog seed via `heki upsert` shell loop logs 38
> `out-of-band:` lines. The same operation as `Subcommand.RegisterMany`
> taking `list_of(SubcommandSpec)` logs 38 `dispatch:` lines (or one,
> with bulk-shape detection — see PR #483).

Once you can see the gap, you can close it. Inbox items i112 / i113 /
i114 / i116 all began as audit-channel observations.

## See also

- `hecks_life/src/heki.rs` — `WriteContext` definition + `audit_write`
- `hecks_life/src/runtime/mod.rs` — breadcrumb write
- `docs/usage/cli_subcommand_catalog.md` — the catalog gate that the
  audit channel exposed
