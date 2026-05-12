# Macrophage — the innate gate of the bluebook-first immune system

`macrophage` is the write-time arm of the discipline machinery. It
engulfs imperative writes the moment they land — the `PostToolUse`
hook fires on every Edit / Write / MultiEdit, asks the macrophage
binary to classify the file, and surfaces a complaint to stderr if
the write should have been a bluebook.

The companion gate is the [antibody](antibody.md). Antibody binds at
commit-time ; macrophage engulfs at write-time. Together they're the
**innate + adaptive immune system** for bluebook-first discipline.

| Cell | Trigger | Layer | Speed |
|---|---|---|---|
| Macrophage | PostToolUse hook on file write | Innate — pattern-based | Fast, per-edit |
| Antibody | Pre-commit + CI | Adaptive — staged-set audit | Slow, per-commit |

The narrative arc reads cleanly :

> Macrophage detects the non-bluebook write → presents the gap →
> antibody binds at commit time → the gap stays named in the commit
> trailer or it doesn't land.

## What it enforces

Every imperative write needs *something* to justify it. The macrophage
recognises three escape hatches, in order :

1. **The file is dispatched by the corpus.** The runtime's
   `is_dispatched_by_corpus` query asks the IR : does any
   `.bluebook` or `.hecksagon` claim this file as a generated
   target, an adapter command, or a specializer output ? If yes,
   the file is exempt structurally — no marker needed. The corpus
   already names the gap.

2. **The file carries an `[antibody-exempt: …]` marker.** A
   one-time, file-scoped exemption with a concrete reason. The
   marker IS the audit trail — there is no out-of-band registry.

3. **Nothing.** Then the macrophage complains, the complaint
   prints to stderr, and Claude Code surfaces it as a system
   reminder on the next turn.

The complaint isn't a block. Some imperative code IS the right
answer (kernel-surface Rust, transitional shell with retirement
markers). But every complaint forces the author to **name** the
exemption in the moment instead of drifting.

### The four structural principles (locked 2026-05-12)

The mechanical contract — classify by extension, demand a marker —
is the surface. The deeper contract is four principles the macrophage
defends :

- **Domain is pure.** Bluebook-first applies to every imperative
  file ; unblessed `.rs` / `.rb` / `.py` / `.sh` / `.go` / `.ts` /
  `.js` writes complain.
- **Wiring is override, not substrate.** Adapters live in
  `.hecksagon` files, not inside `.bluebook` files ; bluebooks
  that hard-code adapter wiring as if it were required get
  flagged.
- **Default-to-memory works.** Imperative code that pretends to be
  substrate when the domain should run in memory is a smell ; the
  macrophage learns to recognise it.
- **Infrastructure is invisible.** A bluebook that leaks
  hibernation state (heki paths, process boundaries, persistence
  concepts) into domain attributes breaks the metaphor — the
  domain doesn't know it hibernates.

The first principle is mechanical (regex + file classification, live
today). The other three are deeper — they need IR-level checks
(does this bluebook attribute reference a persistence concept ?) and
are iterated as registered checks land.

## The three gates (i553)

The macrophage is **one binary running in three places** :

1. **Write-time** — `PostToolUse` hook on Edit / Write / MultiEdit.
   Catches each edit as it lands. Dispatches a
   `Macrophage.Record<Kind>Edit` command and, for imperative files
   without an exemption, chains into `Macrophage.Complain` so the
   complaint reaches stderr.

2. **Commit-time** — `pre-commit` hook (Gate 5). The same binary
   audits the staged set before the commit lands. Catches anything
   that slipped past a missing or stale PostToolUse hook.

3. **CI** — `.github/workflows/macrophage.yml` runs
   `storehouse macrophage audit` over the whole repo. Same binary,
   same logic, scoped to "every file in the tree."

Local and CI run the **same binary** with the **same logic.** If
local passes, CI passes. If CI fails, local would have failed too.
No drift between gates by construction.

## The Check entity

Registered enforcement rules live as `Check` entities **inside** the
Macrophage aggregate. Each `Check` carries :

| Attribute | Concept |
|---|---|
| `id` | Stable slug — `fixtures_at_runtime`, `wiring_in_bluebook`, etc. |
| `pattern_kind` | Detection-strategy name the kernel knows how to apply |
| `severity` | `block` (hard stop) or `warn` (surface, don't block) |
| `complaint` | The stderr text to emit when the rule matches |
| `triggered_count` | How many times this rule has fired |

The kernel scans live file operations, matches against each
registered `pattern_kind`, and on match dispatches `TriggerCheck`
(which bumps `triggered_count`) and `RecordViolation` (which appends
a concrete `Violation` entity carrying `check_id`, `file_path`,
`violated_at`). The rule definition stays clean ; the activations
accrete as audit trail.

`Check` was originally its own `MacrophageCheck` aggregate. On
2026-05-12 it folded into Macrophage per the "domain is dense"
principle — one aggregate carries the counters, the registered
checks, the complaint history, and the violation log as four child
entity collections.

## What you see when it fires

```
macrophage : imperative-language file written without exemption
    rust/src/some_new_file.rs

  Bluebook is the source AND the thing that runs. Either rewrite
  this concept as a .bluebook / .hecksagon pair, or add an
  [antibody-exempt: …] marker that names the concrete gap and how
  it'll close.
```

The complaint lands in stderr ; Claude Code lifts it into the next
turn as a system reminder. The agent then either retires the file
to a bluebook or names the exemption inline. Drifting silently is
no longer an option.

## References

- Bluebook source —
  [`hecks_conception/aggregates/discipline/macrophage/macrophage.bluebook`](../../hecks_conception/aggregates/discipline/macrophage/macrophage.bluebook)
- Sibling aggregate —
  [`hecks_conception/aggregates/discipline/antibody/antibody.bluebook`](../../hecks_conception/aggregates/discipline/antibody/antibody.bluebook)
- Companion doc — [antibody.md](antibody.md) — the commit-time gate
- Inbox cards —
  [`hecks_conception/inbox/i531.md`](../../hecks_conception/inbox/i531.md)
  (rename), [`hecks_conception/inbox/i553.md`](../../hecks_conception/inbox/i553.md)
  (three gates + CI parity)
- Corpus-dispatch query — `rust/src/dispatch_query.rs`
  (`is_dispatched_by_corpus`) — the structural exemption path
