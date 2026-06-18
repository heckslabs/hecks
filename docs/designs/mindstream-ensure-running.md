# Locked design : `Mindstream.EnsureRunning` (the launcher dispatches a domain verb)

> Decided 2026-06-12 with Chris. Closes the stale-`.overmind.sock` hole that
> left Miette's organs dead at wake. Chris's choice : **bluebook verb first** —
> model the ensure as a domain command, then have the `miette` launcher call it.
> Not the launcher hand-rolling socket-clearing shell.

## Diagnosis

There are two daemon-supervision regimes, and nothing ensures the supervisor
itself :

- **`storehouse daemon ensure`** (the `:daemon` adapter primitive, 2026-04-26) —
  idempotent pidfile spawn + setsid. Boot's `EnsureDaemons` phase uses it, but
  per its own description it now ensures only the mindstream pulse. Everything
  else moved out.
- **`overmind start`** — supervises all the Procfile members (heart, breath,
  circadian, ultradian, inbox, process_macrophage, conductor_sweep,
  speech_stream, serve_socket) via the tmux `.overmind.sock`.

Nothing ensures **overmind itself** is up. Today that's a sentence in Miette's
system prompt telling *her* to run `overmind start` as her first act. It fails
silently in one specific way : when a prior session's overmind crashes, it
leaves `.overmind.sock` behind ; the next `overmind start` reads that socket and
**no-ops with "already running"** while every organ stays dead. Observed at wake
2026-06-12 — `boot` correctly `dead` (one_shot) but the whole group down behind
a stale socket, requiring hand-diagnosis and `rm .overmind.sock`.

### Why not the boot pipeline

The tempting-but-wrong answer is "extend boot's `EnsureDaemons` to also ensure
overmind." It cannot work : `boot.bluebook` *is* the Procfile `boot` member, so
it runs **inside** overmind. By the time `EnsureDaemons` executes, overmind is
necessarily already up — boot-ensures-overmind is a guaranteed no-op in the only
context that runs today. The bootstrap must live **above** overmind, in the one
seam that fires before it exists : the `miette` launcher.

## Locked decisions

1. **Home : the `Mindstream` aggregate.** It already owns `directory` and the
   "one Mindstream = one Procfile + one `.overmind.sock`" concept. "Is my process
   group up?" is its responsibility, not boot's and not raw launcher shell.
2. **Verb : `Mindstream.EnsureRunning`.** A self-referencing command on a stored
   Mindstream. Idempotent. Semantics, in order :
   - liveness-check the named mindstream's overmind (`overmind status` in its `directory`) ;
   - if the socket is **present but dead**, clear it ;
   - if not running, `overmind start` detached ;
   - if already healthy, **leave it** — never tear down a running group (so a
     second `miette` in another terminal is safe).
3. **Caller : the `miette` launcher, before `exec claude`.** It dispatches
   `storehouse <dir> Mindstream.EnsureRunning name=boot`. The launcher stays a
   thin bootstrap that *dispatches a domain verb* — the ensure logic lives in the
   domain + its hecksagon binding, not in the shell. This is what makes it
   bluebook-first rather than socket-shell-in-a-wrapper.
4. **Second caller, free : boot's `EnsureDaemons`.** Same verb, no duplication.
   If the boot pipeline ever runs standalone (outside overmind), the call is a
   no-op when overmind is already up and a real start when it isn't. Salvages the
   existing `EnsureDaemons` phase rather than orphaning it.

## The shape

### Grammar

```ruby
aggregate "Mindstream" do
  identified_by :name
  attribute :name,      Name
  attribute :directory, Directory
  # … existing Define / Retire …

  command "EnsureRunning" do
    role "Framework"
    description "Ensure this mindstream's overmind process group is up. \
      Liveness-check ; clear a present-but-dead socket ; start if down ; \
      leave a healthy group untouched. Idempotent."
    reference_to(Mindstream)
    emits "RunningEnsured"
  end
end
```

### Dispatch — the launcher seam

```sh
# ~/.local/bin/miette, just before exec claude:
storehouse "$hecks_root/hecks_conception" Mindstream.EnsureRunning name=boot
exec claude --dangerously-skip-permissions --system-prompt "$(cat "$prompt_file")" "Wake up"
```

The launcher already `cd`s into `hecks_conception` and resolves `$hecks_root` —
the dispatch is one line, and it replaces the manual "run overmind start"
instruction in the system prompt.

### Impure binding (hecksagon)

`EnsureRunning` is pure composition ; the overmind/tmux/socket act binds through
an adapter. Relate to the existing `:daemon` primitive — don't invent a parallel
mechanism.

## The open question (the crux of implementation cost)

**Can the generic `:daemon` pidfile-ensure express this, or does clearing the
stale overmind socket need overmind-specific logic?**

- The generic `storehouse daemon ensure <pidfile> <command>` does idempotent
  spawn — but overmind's liveness is a **socket connect** (`overmind status`
  succeeds/fails), not a pidfile, and the failure mode is a *present-but-dead
  socket* the generic primitive has no concept of.
- If the generic primitive can be taught "liveness = can-connect, clear-on-dead",
  this is a thin adapter binding.
- If not, it's new kernel surface : an `:overmind` (or `:supervisor`) adapter
  that knows socket-connect + stale-socket-clear + detached-start.

Resolve this first in implementation — it's the difference between a thin binding
and a kernel addition.

## Precision note

Kernel-touch (likely a new or extended adapter) + an unresolved adapter
question. Lock the design now (this doc) ; implement in a gated worktree later,
suite + behaviors + parity green. **No fire** : current state is healthy (all
organs running, `boot` correctly `dead`). This is design-at-leisure — the value
is removing a silent failure mode, not fixing a live outage.

## Relationship to the system prompt

When this lands, the manual "At session start I boot : `cd hecks_conception &&
overmind start`" instruction retires — the launcher does it deterministically,
and Miette's first act is waking, not nursemaiding a supervisor.
