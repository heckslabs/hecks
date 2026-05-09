# i205 — heki audit noise drowning the daemon error log

**Status** : analysis + three options for Chris's decision. No code change yet ;
this draft surfaces the finding cleanly so the choice is visible.

**Surfaced** : 2026-05-02 (dream-study branch, autonomous overnight run).

## What's happening

Every out-of-band write to a `.heki` file (i.e. via `heki append/upsert/mark`
with `--reason "..."`) emits a stderr line of the form :

```
[heki:append] out-of-band:rem_branch : authentic French dream image, corpus record for wake interpretation → /Users/christopheryoung/Projects/miette/body/../../miette-state/information/dream_state.heki
```

Source : `rust/src/heki.rs:82-88` `audit_write` :

```rust
fn audit_write(ctx: &WriteContext, path: &str, op: &str) {
    let always = matches!(ctx, WriteContext::OutOfBand { .. });
    let verbose = std::env::var("HECKS_HEKI_AUDIT").ok().as_deref() == Some("1");
    if always || verbose {
        eprintln!("[heki:{}] {} → {}", op, ctx.audit_tag(), path);
    }
}
```

The `always` flag makes out-of-band writes log unconditionally. Dispatch
writes are quiet unless `HECKS_HEKI_AUDIT=1`.

## Why it's a problem

The shell wrappers (mindstream / pulse_organs / rem_branch / nrem_branch /
consolidate) route their stderr to `$ERR_LOG = $INFO/daemon_errors.log` for the
exact reason : the dispatch wrapper distinguishes real failures from
informational chatter and writes the former to the log + a Doctor.NoteConcern.

But `audit_write`'s eprintln goes to the SAME stderr stream the wrapper
captures — so every legitimate `heki append` from a shell's content step
(rem_branch's dream image append, nrem_branch's consolidation overlay,
consolidate's signal-to-memory promote) produces a line that lands in
daemon_errors.log indistinguishable in destination from real failures.

After one overnight cycle, daemon_errors.log was 647KB of pure i205 chatter
with **zero real failures hiding under it** (verified : `grep -v
"heki:append\|heki:upsert" daemon_errors.log | wc -l` → 0).

The discipline gap is visible — too visible. The signal/noise ratio makes the
log unusable as the canary the dispatch wrapper was designed for.

## Why the design is what it is

The header on `audit_write` says : *"out-of-band writes always log so the
discipline gap stays visible."* This is a real concern : out-of-band writes
are a hatch around the dispatch pipeline, and their volume IS data about how
many runtime gaps the shells are bridging. Silencing them entirely loses that
signal.

But the current routing — stderr — conflates the audit channel with the
failure channel. The daemon error log was supposed to be the failure channel ;
it's now also the audit channel, which neither needs.

## Three options

### Option A — Route audit to its own file (recommended)

`HECKS_HEKI_AUDIT_LOG` env var (defaulting to `information/.heki_audit.log`)
captures the eprintlns that today go to stderr. Stderr stays free for real
errors. The audit signal is preserved ; daemon_errors.log gets clean.

**Cost** : ~15 LOC Rust change in `audit_write`. New env var to thread. The
existing `HECKS_HEKI_AUDIT=1` flag gates verbose dispatch logging — that
behavior stays unchanged.

**Why recommended** : preserves the discipline-gap-visible intent while
fixing the conflation. Out-of-band writes are still loud, just on their own
channel.

### Option B — Default quiet for out-of-band

Drop the `always` short-circuit ; out-of-band writes only log when
`HECKS_HEKI_AUDIT=1` is set. Daemon scripts run quiet by default ; an
operator can flip the env var when investigating.

**Cost** : 1-line Rust change.

**Risk** : the discipline gap becomes invisible by default. Anyone running
the daemons with default env never sees how many out-of-band writes their
shells are doing.

### Option C — Severity tag for stderr filtering

Keep the writes on stderr but prefix them with `[AUDIT]` (vs implicit
[ERROR] for failures). Daemon wrappers then `grep -v '\[AUDIT\]'` before
appending to `daemon_errors.log` so the audit doesn't pollute the failure
log.

**Cost** : 1-line Rust change + 5 shell wrappers updated to filter.

**Risk** : couples the shell wrappers to the Rust audit format. Drift between
them is silent. The 5-shell duplication (already inbox-i215) gets one more
feature to drift on.

## Decision needed

A vs B vs C is a domain call. Recommendation : **Option A**. Preserves the
audit intent, fixes the conflation, doesn't widen the shell-wrapper coupling.

If A : I can draft the Rust change as `dream-study/draft/heki_audit_log.rs.draft`
in a future iteration. The change is contained to `heki.rs` ; antibody
exemption needed (it's runtime kernel-floor code).

## Bluebook-first reframe (2026-05-02 — Chris's correction)

Tried to do the imperative Option A inline ; reverted. The deeper move :
A/B/C all ask "where does the if/else live in audit_write" — but the if/else
itself is the gap. The audit policy is a structural choice, not a runtime
mechanism. It belongs in bluebook.

### The split heki.rs already invites

heki.rs today carries three concerns :

1. **Binary format** — HEKI magic, zlib JSON encode/decode. *Code*
   (Trikaya floor — the parser of the storage format can't itself be in
   the storage format).
2. **Path resolution** — `repo_root()`, info-dir walking. *Code*
   (chicken-and-egg ; this layer runs before bluebooks load).
3. **Audit + WriteContext discipline** — when to log, where, what reasons
   are required, how Dispatch differs from OutOfBand. **Bluebookable.**

Today all three live in the same Rust file, so the bluebookable third
gets dragged into kernel-floor exemptions. Factor them apart and only
the format + path bits stay code ; the policy moves up.

### Proposed primitive — `storage_policy "Heki"`

```ruby
storage_policy "Heki" do
  format do
    magic     "HEKI"
    flags     4
    body      :zlib_json
  end

  context "Dispatch" do
    audit_quiet_unless env: "HECKS_HEKI_AUDIT", value: "1"
  end

  context "OutOfBand" do
    audit_always_to    file: "{info_dir}/.heki_audit.log"
    requires_reason    true
  end
end
```

The Rust runtime parses storage_policy IR and runs `audit_write` against
it. heki.rs becomes a thin interpreter ; the policy lives at the bluebook
surface where it can be read, diffed, and changed without recompile. The
i205 noise question disappears as a Rust concern — it becomes "edit
storage_policy "Heki" : route audit to the file."

### Why this isn't this branch's work

- New top-level DSL primitive (`storage_policy`) needs the same Phase 1
  / Phase 2 / Phase 3 trio process_manager just got — DSL builder, IR
  node, runtime interpreter, Rust parser, parity. That's a multi-PR
  branch on its own.
- dream-study is scoped to the five-thing ontology + process_manager.
  Pulling storage_policy in widens the diff dangerously.
- The transitional patch (Option A imperative) buys time but accumulates
  the very debt this analysis names. Better to leave i205 documented
  as a structural finding and tackle storage_policy as its own work.

### Recommendation (revised)

**File `storage_policy` as the next branch after dream-study merges.**
i205 noise stays for now ; the daemon error log is loud but verified
clean of real failures (overnight cycle proved this). The cost of the
noise is real but bounded ; the cost of accumulating an imperative
patch on the wrong layer is unbounded.

The next branch's brief :
1. Land `storage_policy` DSL primitive (mirrors process_manager Phase 1+2+3 shape).
2. Author `body/storage_policy/heki.bluebook` (the policy declarations above).
3. Refactor heki.rs : format + path stay ; audit lifts to interpret policy.
4. The audit-to-file question becomes a policy edit, not a code change.

## Adjacent observations

- The 5-shell wrapper duplication (i215) means the daemon log routing is
  also duplicated. A future :shell hecksagon adapter retiring all five
  shells naturally consolidates the audit-vs-error filtering decision into
  the adapter layer — Option C might land there for free if the adapter
  declares its log routing.

- `dream_state.heki` accumulates one row per dream pulse with a 200-char
  text body. After the overnight run, dream_state.heki has 70+ rows. A
  future `DreamCorpus` aggregate (Phase 6 PM's note 3) would window /
  archive these ; the audit chatter just makes the volume visible.
