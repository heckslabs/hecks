# Should the framework and grammar chapters get Cargo features of their own?

**Status:** Proposed — draft for review. Design only; nothing in this document is
implemented, and no Cargo feature, corpus kind or generated module changes with it.
It answers item 6 of an outside production-readiness review, which said `chess` had
never been run through `bin/project_rust` and that the framework/grammar chapters
"have no Cargo feature of their own to build". The `chess` half is stale (below).
The chapters half is true, and the question it raises is worth deciding on purpose.

## Context

### What is true today

`rust/Cargo.toml` declares one feature per Rust-facing *domain*: an in-repo domain
directory (`examples/*`, `qa/stress_domains/*`, `spec/fixtures/rust_project/*`,
`Hecks::Corpus::RUST_DOMAIN_KINDS`) whose generated module carries its own
`merged.rs`. Every list that matters reads that one table: the differential fuzz
bridge (`Hecks::Corpus.rust_domains`), `bin/regen_codegen_domains` (the drift check),
`bin/rust_coverage`, and codegen parity. The domain features are mutually exclusive:
one of them becomes `active`, which is the store and dispatch table `kernel/cli.rs`
runs.

`chess` is one of those domains and has been for a long time. It has a feature, a
committed `rust/src/generated/chess/`, a slot in `bin/regen_codegen_domains`, a
pinned conformance fixture (`argument_gate_order_chess.json`) and a fuzz-bridge slot.
`bin/project_rust examples/chess` regenerates it with no diff, and its corpus script
replays byte-for-byte identically on Ruby and Rust.

The five chapters in question are not domains in that sense:

| Chapter | Where it lives | Generated Rust today | Replayed against Rust |
|---|---|---|---|
| `governance` | `lib/hecks/framework/bluebook/` | `rust/src/generated/governance/`, unconditional `pub mod`, no `merged.rs` | inside any domain that `uses_framework "Governance"` (banking, compliance, pizzas, ...); a few pinned fixtures dispatch it |
| `identity` | same | `identity/`, same shape | inside banking; a few pinned fixtures |
| `console_settings` | same | `consolesettings/`, same shape | inside `checkout_fixture` only |
| `expression` | `lib/hecks/grammar/` | none | nowhere |
| `translation` | `lib/hecks/grammar/` | none | nowhere |

Each has a corpus script (`spec/corpus/<name>.json`), replayed on Ruby by `bin/run`
and `spec/corpus_spec.rb`. None of those five scripts is replayed against a Rust
binary. `spec/corpus_rust_spec.rb` deliberately buckets `governance`, `identity` and
`consolesettings` as "framework chapters: no feature and no merged.rs, written as a
side effect of every `uses_framework` domain's regen".
`privacy` (also under `lib/hecks/framework/bluebook/`) is in the same position and
is not named in the review; it is included in the probes below.

### What a feature would cost

A feature is more than a line in `Cargo.toml`. It puts the chapter into every
Rust-facing list at once: a slot in the regen order, a domain-exclusive `cfg` in
`generated/mod.rs`, a share of the fuzz-bridge seed budget, a codegen-parity entry, a
`bin/rust_coverage` row and a conformance build. The corpus model would also have to
learn a directory shape that is not `examples/`, `qa/stress_domains/` or
`spec/fixtures/`, because the framework chapters live under `lib/hecks/framework/`
and the grammar chapters directly under `lib/hecks/grammar/`.

## Evidence

Throwaway probes, run on this branch against current `main`. Nothing was committed;
every generated file was reverted afterwards.

1. **The framework bundle already builds as one domain.**
   `bin/project_rust lib/hecks/framework` succeeds today, because that directory has
   the `bluebook/` subdirectory `bin/project_rust` expects. It writes a `framework/`
   module (the first chapter loaded is treated as the target domain, so the
   Compliance chapter's aggregates land there), regenerates `governance/`,
   `identity/`, `consolesettings/` and `privacy/` as attached chapters, and adds a
   `framework` feature to `Cargo.toml`. `cargo build --no-default-features
   --features framework` compiles.
2. **Replaying the corpus scripts through it.** Compared field by field with the same
   comparison `spec/rust_conformance_spec.rb` uses:
   - `governance.json`, `identity.json`, `privacy.json`: identical to Ruby.
   - `console_settings.json`: **diverges.** A `list_of` value-object element with
     absent optional fields is serialized by Rust with explicit `null` keys
     (`{"field": "reference", "sortable": null, "sort_default": null, "extra_json":
     null}`) where Ruby omits them (`{"field": "reference"}`). It shows up in
     `instances` and in the `ColumnsReplaced` and `StatsReplaced` event payloads. This
     is the same class as audit item R1 ("Rust emits `nil` for an omitted optional
     where Ruby omits the key"), reached through list elements rather than top-level
     arguments.
3. **`expression` and `translation` need a `bluebook/` directory to be a target.**
   `bin/project_rust lib/hecks/grammar` fails with a `KeyError` (`.keys.first` of an
   empty registry), because `lib/hecks/grammar/` holds flat files and no `bluebook/`
   subdirectory, and holds two chapters. With each chapter copied into a scratch
   `<name>/bluebook/` directory, both generate and build:
   - `translation.json`: identical to Ruby.
   - `expression.json`: **diverges.** Ruby refuses `Expression::Operator.Render`
     with an empty `target` (`Rendering invariant violated — a rendering must name its
     target`); Rust accepts it and appends the rendering. The value-object invariant
     on a list element being appended is not enforced in Rust. Every later event and
     refusal index shifts by one as a result.

4. **No feature is needed to replay the framework chapters.** `governance.json` and
   `identity.json` replayed against the existing banking binary
   (`examples/banking`, `--features banking`) are identical to Ruby, and
   `console_settings.json` replayed against the existing `checkout_fixture` binary
   shows the same divergence as probe 2. The chapters' verbs are already dispatchable
   in the binaries of the domains that attach them.

So two of the five chapters hide a real Ruby/Rust divergence today, precisely because
nothing replays their corpus against Rust. The other three agree.

## Options

**Option A — no features; status quo.** Chapters stay covered as attached
dependencies. Cost: nothing. But it leaves `console_settings` and `expression` as
unchecked claims, and leaves `expression` and `translation` with no generated Rust at
all.

**Option B — one feature per chapter** (`governance`, `identity`, `console_settings`,
`expression`, `translation`, and `privacy`). Each gets its own conformance run and
fuzz slot. Cost: the three chapters that already have a module (`governance`,
`identity`, `consolesettings`) would then be both an unconditional attached chapter
and a domain with a `merged.rs`, which contradicts the partition
`spec/corpus_rust_spec.rb` proves (a module is a domain *or* a chapter, never both).
Six new entries in every Rust-facing list, most of them tiny, and each needs the
`uses_framework "Governance"` hecksagon binding to boot standing alone.

**Option C — one `framework` feature, bundling the chapters under
`lib/hecks/framework/`; grammar chapters handled separately.** This is what probe 1
already does with no code change. One slot in every list, one binary that can replay
`governance`, `identity`, `console_settings`, `privacy` (and Compliance-the-chapter).
The bundle stays a "domain" in the corpus model with the source of truth left in
`lib/hecks/framework/`; the model needs one new kind (say `:framework_bundle`) added
to `RUST_DOMAIN_KINDS`. It does not remove the need for a decision on the grammar
chapters.

**Option D — conformance without features: replay the chapter scripts against an
existing binary that already contains the chapter.** `governance` and `identity`
verbs are dispatched by banking's binary; `console_settings` by `checkout_fixture`'s.
Promote those scripts as extra corpus members in `spec/rust_conformance_spec.rb` with
the host domain named. No new feature, no new corpus kind. Does not help `expression`
or `translation`, which no Rust domain attaches.

**Option E — Option D for the framework chapters, plus features for the two grammar
chapters only, with the chapters relocated so each has a `bluebook/` directory.** The
grammar chapters are the ones with no Rust artifact at all, so they are the only ones
that need a build target. Relocating them is a real cost: `lib/hecks/grammar/`'s paths
are referenced by `Hecks::Corpus` (`FILE_KINDS[:grammar]`), the boot path and
`spec/corpus_spec.rb`.

## Recommendation

Not to implement here. If asked for a preference: **Option D for `governance`,
`identity` and `console_settings` now, and decide `expression` and `translation`
separately**, because they are different problems.

- The framework chapters are already compiled into Rust binaries and already
  dispatchable. What is missing is a script that replays their corpus against one of
  those binaries, which is a spec entry, not a feature. That avoids the
  module-is-a-domain-or-a-chapter conflict in Option B and keeps the number of
  mutually exclusive features from growing. Option C is the fallback if the host
  domain's own state makes the replay noisy.
- The grammar chapters have no Rust artifact, so a feature is the only way to get
  one. They are also the chapters that define the expression sublanguage Rust's
  `kernel/expr.rs` evaluates (ADR 0022 proposes self-hosting it). A conformance
  check on `expression` is therefore more than housekeeping, and probe 3 shows it
  already finds a divergence. Whether that is worth a feature and a relocation is a
  maintainer call.
- Either way, the two divergences in the evidence section should be filed as bugs
  (Rust is the side to fix: Ruby is canonical), independent of this decision.

## Decisions needed

- **D1.** Are the framework chapters conformance-checked through their host domains
  (Option D), as one bundle feature (Option C), or as one feature each (Option B)?
- **D2.** Do `expression` and `translation` get Rust builds at all, and if so, is
  relocating them into `bluebook/`-shaped directories acceptable?
- **D3.** `privacy` and Compliance-the-chapter are in the same position and were not
  named in the review. In scope for whatever is decided for the others?
- **D4.** File the `console_settings` (list-element optional fields serialized as
  `null`) and `expression` (list-element value-object invariant not enforced)
  divergences as issues now?

## Consequences

If Option D is taken, `governance`, `identity` and `console_settings` gain byte-for-byte
Rust coverage at the cost of a few spec entries, and the `console_settings` gap gets
found and fixed in the process. If a feature is added for any chapter, the
`Hecks::Corpus` partition, `bin/regen_codegen_domains` and the fuzz-bridge budget each
change with it, and the change should ship with the corpus-model change that names the
new kind. If nothing is done, the two divergences stay invisible.

## Verification done for this ADR

Read directly: `rust/Cargo.toml`, `rust/src/generated/mod.rs`, `lib/hecks/corpus.rb`,
`spec/corpus_rust_spec.rb`, `spec/corpus_spec.rb`, `bin/project_rust`,
`bin/regen_codegen_domains`, `spec/rust_conformance_spec.rb`. Run: the probes in the
Evidence section (`bin/project_rust` on the framework directory and on scratch copies
of the two grammar chapters, `cargo build --features <name>`, and the corpus scripts
replayed through the conformance comparison, including `governance.json` and
`identity.json` against the banking binary and `console_settings.json` against the
`checkout_fixture` binary), and the `chess` corpus and a new chess refusal fixture
through the chess binary. Not run: the fuzz bridge, codegen parity or
the drift check against any hypothetical new feature, and a Postgres-backed replay of
any chapter.
