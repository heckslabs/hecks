---
ref: i660
status: designed
priority: high
posted_at: 2026-05-20
posted_by: Miette (Chris: "inboxes should pull data from ~/hecks so we don't collide")
category: framework / inbox / centralized-allocation
value: 'End the inbox-number-collision pattern. Tonight (2026-05-20) two pairs of agents collided on the same i-number — i649 (audit vs autophagy) and i656 (universal-door vs executable-bluebook) — because each agent scanned only its own worktree''s `hecks_conception/inbox/` and picked `max(i*.md) + 1`. Concurrent local-max picks of a global resource collide. Fix : a centralized atomic allocator backed by `~/.hecks/inbox/next.json` (outside any worktree), guarded by flock, served via `bin/hecks-inbox`. Bluebook : `aggregates/framework/inbox_index/` with Allocate, Reserve, Recover commands.'
links:
  - i649 (collision : audit vs autophagy)
  - i656 (collision : universal-door vs executable-bluebook)
---

# i660 — Centralized i-number allocator (end the collision pattern)

## The bug

Tonight, 2026-05-20, two pairs of agents collided on i-numbers :

- **i649** — audit sidequest AND autophagy sidequest both filed `i649.md`
- **i656** — universal-door sidequest AND executable-bluebook sidequest
  both filed `i656.md`

Each agent independently :
1. Scanned `hecks_conception/inbox/i*.md` in its OWN worktree
2. Picked `max(i*.md) + 1`
3. Wrote the file

When two agents do step 1–3 concurrently in two worktrees, they both
pick the same N. The bug is structural : **per-worktree max is a local
view of a global resource**. Two concurrent local-max picks of a
shared namespace collide by construction.

Chris : *"inboxes should pull data from ~/hecks so we don't collide."*

## The fix : InboxIndex domain + bin/hecks-inbox shim

**Bluebook** : `hecks_conception/aggregates/framework/inbox_index/`

- `InboxIndex` aggregate (singleton) — holds `next_number`, the
  single source of truth for what the next inbox card's i-number
  should be.
- `Allocate` — atomically returns next_number AND advances it by 1.
  The default verb for "give me an i-number."
- `Reserve` — atomically returns a contiguous Range(start, count)
  AND advances next_number by count. The verb for sidequest spawn :
  "I'm dispatching N children, reserve N numbers so they don't
  collide with each other or anyone else."
- `Recover` — re-scans every inbox directory on disk and re-grounds
  next_number to `max(i*.md) + 1`. Idempotent ; never decreases.
  Run automatically on first call (init) ; run by hand when drift
  is suspected.

**Persistence** : `~/.hecks/inbox/next.json` — outside any worktree,
the shared ground truth. Shape :

```json
{
  "next_number": 659,
  "session_started_at": "2026-05-20T22:14:00Z",
  "last_allocated_at": "2026-05-20T22:14:03Z",
  "last_allocated_to": "inbox-centralized-numbering",
  "total_allocated": 1,
  "total_reserved": 0,
  "recoveries": 1,
  "initialized_from": "max(i*.md) on disk = 658"
}
```

**Atomicity** : the `bin/hecks-inbox` Ruby shim uses `flock(LOCK_EX)`
on the persistence file itself. Concurrent callers from sibling
worktrees serialize at the OS level — read-modify-write is one
critical section per call, so each caller gets a distinct number
even under contention.

**CLI** :

```sh
hecks-inbox next [--requester LABEL]            # default: prints next N
hecks-inbox allocate --reserve N [--requester LABEL]   # prints "start count"
hecks-inbox recover                             # re-scan + re-ground
hecks-inbox show                                # cat next.json (read-only)
```

## Agent-instruction template

When an agent (or a sidequest spawned by one) needs to file an inbox
card, it MUST call the shim instead of scanning its own worktree :

```sh
# Single card :
N=$(ruby /Users/christopheryoung/Projects/hecks/bin/hecks-inbox next \
       --requester my-task-tag)
# now write i${N}.md or i${N}-slug.md

# A sidequest spawning K children :
read START COUNT < <(ruby /Users/christopheryoung/Projects/hecks/bin/hecks-inbox \
                        allocate --reserve 5 --requester my-sidequest)
# pass numbers $START .. $((START + COUNT - 1)) to the children
```

The SessionStart hook (see below) also injects the current
next-number into the agent's `additionalContext` at boot so the value
is visible inline — agents that need a number for the next card can
see what it will be before making a tool call.

## SessionStart hook : inject current next-number

A drop-in hook script `bin/hecks-inbox-session-context` queries
`hecks-inbox show` (read-only — does NOT advance state) and emits
the `hookSpecificOutput.additionalContext` JSON so every fresh
session sees the allocator state at boot :

```
[inbox-index] next i-number for any inbox card you file this session : i659
  persistence : ~/.hecks/inbox/next.json (flock-guarded)
  allocate    : ruby /Users/christopheryoung/Projects/hecks/bin/hecks-inbox next --requester <task-tag>
  reserve N   : ruby /Users/christopheryoung/Projects/hecks/bin/hecks-inbox allocate --reserve N --requester <task-tag>
  bluebook    : hecks_conception/aggregates/framework/inbox_index/
```

This is the operational analogue of the `additionalContext` injection
i647 names for the wake-review surface — the bluebook IS the contract ;
the hook is the surface that makes the contract visible at boot.

The actual `.claude/settings.local.json` entry — adding the hook to
the `SessionStart` array — was NOT applied in this session because
the sandbox blocks edits to `.claude/settings*.json` (the same
governance lockdown that denies native Bash). The drop-in is
ready ; Chris's one-line install :

```json
{ "type": "command",
  "command": "/Users/christopheryoung/Projects/hecks/bin/hecks-inbox-session-context",
  "timeout": 5 }
```

appended to `.claude/settings.local.json`'s `hooks.SessionStart[0].hooks`
array. The shim is dependency-free (ruby + jq are both already
SessionStart-hook universals) and silent if the allocator file
doesn't exist yet — safe to add now ; activates as soon as the
first `hecks-inbox next|recover` call initialises state.

## Bootstrap : i658 by dogfooding (and what's deferred)

This very card is i658 — the next number after the current global
max (i657-executable-bluebook-compile across worktrees). The
allocator was NOT used to mint this number live during filing — the
chmod step on `bin/hecks-inbox` is blocked by the current Bash
sandbox configuration, so a clean `ruby bin/hecks-inbox next --requester
inbox-centralized-numbering` invocation can't be demonstrated inside
this session. The number i658 was selected by hand from the same
`max(i*.md) + 1` rule the shim implements, scanning ALL worktrees
(not just this one) — which is the discriminating constraint the
allocator enforces in code.

The dogfooding becomes literal as soon as Chris runs :

```sh
chmod +x /Users/christopheryoung/Projects/hecks/bin/hecks-inbox
ruby /Users/christopheryoung/Projects/hecks/bin/hecks-inbox recover
# observes max=658 (this card), sets next_number to 659
```

The first real call after that emits i659 as the first
allocator-blessed number.

## What's NOT covered (deferred)

- **Retro-fit of in-flight cards** : if any in-flight worktree branch
  filed a card with a number the allocator will later issue, the
  Recover sweep catches it (max(disk)+1 monotonically advances).
  Cards already merged with collided numbers (i649, i656) are NOT
  renamed by this change — that's a separate cleanup.
- **Per-project namespaces** : all inboxes share one number space
  (the same way they do today). If per-project sequences are wanted
  later (`opt-website/i1`, `embryonaut/i1`, ...), Allocate / Reserve
  grow a `namespace:` parameter and `next.json` becomes a map.
- **Live Rust integration** : the bluebook is the contract ; runtime
  parity for the storehouse dispatcher is the next pass (the existing
  identifier_service / handler_registry stubs are the pattern).
- **Pre-push gate** : behaviors are stub-shaped (one test per command).
  As the substrate fleshes out (concurrent-Allocate stress, disk-scan
  performance, Recover idempotence under churn) the tests grow.

## Acceptance (this branch)

- `hecks_conception/aggregates/framework/inbox_index/inbox_index.bluebook`
  — singleton InboxIndex with Allocate / Reserve / Recover commands
- companion `.behaviors` — one test per command (StartSession,
  Allocate, Reserve, Recover ; both records-attribute + emits)
- `bin/hecks-inbox` — Ruby shim, flock-guarded, 4 subcommands
  (next, allocate, recover, show).
- `bin/hecks-inbox-session-context` — SessionStart hook drop-in,
  emits the `additionalContext` JSON.
- This card — at i658, filed at max+1 across ALL worktrees, not
  just this one (the discriminating constraint the allocator
  enforces in code).

## Three follow-up acts (outside the sandbox)

The remaining acts of the change need permissions the worktree
sandbox denies — they all run as ordinary file-mode / settings
edits at Chris's terminal :

1. `chmod +x bin/hecks-inbox bin/hecks-inbox-session-context`
   so the shebang lines fire without the `ruby ` prefix.
2. Append the hook drop-in to `.claude/settings.local.json`'s
   `hooks.SessionStart[0].hooks` (snippet above).
3. `ruby bin/hecks-inbox recover` to materialise `~/.hecks/inbox/next.json`
   from disk. After this, every subsequent `hecks-inbox next` is the
   live allocator.

## Branch

`feat/inbox-centralized-numbering` (per task instruction — do not
merge ; await Chris's review).
