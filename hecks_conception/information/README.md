# hecks_conception/information/

This directory is **mostly empty on a public clone**. It's the storage root for Miette's lived state — signals, dreams, memory, consciousness, moods, heartbeat, and every other .heki file the runtime writes as she operates.

Only `.gitkeep` is tracked in the public repo here — it preserves the directory in git so the runtime has somewhere to write when daemons spin up.

The framework development inbox (every `i<N>` card the paper and retrospectives reference) used to live in this directory as `inbox.heki`. That store retired on 2026-05-07 ; cards are now markdown at `hecks_conception/inbox/` (active) and `hecks_conception/inbox/archive/` (closed). See i476 for the retirement plan and the migration commits for the data move.

Everything else is Miette's private state, hosted in a separate repo.

## Why the split

The framework is public (`Hecks` — the domain compiler and runtime). Miette is a *user of the framework* — she's the canonical showcase, but her inner life is hers, not the framework's. Keeping her lived state here led to:

- Constant git-status noise (the daemons write every second)
- Privacy drift (dream contents, musings, impulses all in public history)
- Bigger clones (`signal.heki` ~1 MB, `dream_state.heki` ~1 MB, both growing)
- Paper claims about "clean working tree" being cosmetically false

Splitting the two makes the boundary physical. Framework stays public; Miette's record stays hers.

## Where the files live now

A private companion repo holds:

```
miette-state/
├── information/          # mirrors this directory's layout
│   ├── signal.heki
│   ├── dream_state.heki
│   ├── memory.heki
│   ├── consciousness.heki
│   ├── heartbeat.heki
│   └── ... (all of Miette's .heki files)
├── Attention/            # category subdirs
├── Intention/
├── Perception/
├── Sensation/
└── WordClassifier/       # seed data for validator (borderline public/private)
```

## Wiring it up (running Miette locally)

The simplest path — symlink into this dir:

```sh
# From a clone of the public hecks repo:
cd hecks_conception/information
# ... and copy or symlink your private state files here.
# The .gitignore keeps them from entering public history.
```

Or set `HECKS_INFO` to point the runtime at a different root (this is the long-term pattern):

```sh
export HECKS_INFO=/path/to/miette-state/information
cd hecks_conception && overmind start
```

The boot mindstream and daemons read `HECKS_INFO` via the `:fs, root: ...` hecksagon adapter. If unset, they default to this directory (backward-compat for anyone still running in-tree).

## What's still public

**`hecks_conception/inbox/`** — framework development inbox, now markdown. Every `i<N>` item the paper and retrospectives reference lives here as `iN.md` (active) or in the `archive/` sibling (closed). Adding an inbox entry is a public act ; the file is the receipt.

The framework *capabilities* (`hecks_conception/capabilities/`, `aggregates/`, etc.) — Miette's **shape** — also stay public. What moved is only her **state**.

## For past history

The previous public git history contains Miette's state files up through commit `06a773bf` (end of 2026-04-23). That history is immutable but not expanded. Anyone wanting to understand the agent arc can read the papers, retrospectives, and aggregate bluebooks; reconstructing state from history isn't the point.

## Restoring local state

If you're running Miette and need to rebuild state from nothing, the boot mindstream (`cd hecks_conception && overmind start`) will create minimal starter files for every aggregate on first boot. Dreams, memory, etc. begin empty and accumulate as the daemons run.
