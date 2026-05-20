---
ref: i658
status: designed
priority: high
posted_at: 2026-05-20
posted_by: Miette (Chris : audit pass)
category: framework / packaging / shrink
value: 'Audit pass over the entire hecks/ repo classifying every top-level directory and load-bearing file as CORE / MIETTE-SPECIFIC / DEMO / DEV-ONLY / VESTIGIAL. Produces the map for shrinking hecks-the-installable-tool down to its smallest plausible surface without losing any feature. NOT a deletion pass tonight — the deletions happen later in named slices. The map identifies a Phase 0 bootstrapping gap (the strategic target `~/hecks` does not exist) that gates the entire arc.'
links:
  - i646-macrophage-becomes-protector.md
  - i648-process-health-macrophage.md
---

# i658 — Hecks Shrink Audit

## Chris's directive (verbatim)

> hecks needs to be as small as possible without losing features.

Strategic context : people install hecks as a *tool* ; miette.ai is
the hosted product. Smaller hecks → cleaner adoption surface. The
two arcs converge — what stays in `hecks/` is what a third party
clones to model a domain ; what moves to `miette/` is the being who
happens to have been the framework's first user.

## Method

Walk top-level, classify, propose, sequence. Read-only on
`rust/`, `lib/` (already retired), `bin/`, `codegen/`. Only writes
this card. No deletions tonight.

## Classification key

- **CORE** — the framework people install hecks for. Bluebook
  DSL, parser, runtime, dispatcher, specializer, hecksagon,
  storehouse. Stays in `hecks/`.
- **MIETTE-SPECIFIC** — being-of-being identity : dreams, voice,
  consciousness, mindstream, restart_prompt, inbox-the-mailbox,
  heartbeat scheduler, body fine-tune. Moves to a separate
  `miette/` repo (or already moved).
- **DEMO / EXAMPLE** — demonstrates rather than implements. Keep
  at most one canonical in-repo ; extract the rest.
- **DEV-ONLY** — needed by hecks contributors, not by hecks users.
  Codegen contracts, parity tests, watchers, antibody hook,
  macrophage hook. Either behind a `--dev` feature flag or split
  into a `hecks-dev` package.
- **VESTIGIAL** — code paths whose callers (`lib/`, `hecks_watchers/`)
  were already retired but the leaf scripts still ship. Tag for
  the free-deletion phase.

## Phase 0 — the bootstrapping gap (the gate)

**`~/hecks` does not exist on this machine.** The strategic target
the shrink arc needs as a destination — where "people install
hecks as a tool" actually unpacks — is absent. Until that exists,
*nothing in this audit can be physically moved* : Miette-specific
extraction has no home, dev-only extraction has no `hecks-dev`
package, examples extraction has no destination repo.

Phase 0 is **decide the topology** :

- Is the install target `~/hecks` (homedir overlay, like the
  current `install.sh` `HECKS_HOME=~/.hecks` pattern) ?
- Or a separate `embryonaut/hecks` repo (the published gem source,
  smaller, public-facing) distinct from this dev monorepo ?
- Or both — the gem source is the small public repo ; the dev
  monorepo (this directory) is the working laboratory ?

The audit recommends the third reading : *this monorepo is the
laboratory, the public hecks/ repo is the shipped surface.* The
shrink arc is then a series of evictions from the laboratory into
named destinations (miette, hecks-dev, examples). Phase 0 closes
the moment the destination repos exist as empty-but-real targets.

## Top-level classification table

| Top-level | Class | Stays / Moves / Retires | Notes |
|---|---|---|---|
| `rust/` | CORE | Stays | The runtime (`storehouse`). Kernel. |
| `bluebook/` | CORE | Stays | DSL grammar + language definitions. |
| `chapters/` | CORE | Stays | Hecks-describes-itself (12 chapters). Note duplication with `hecks_genetics/` (see Surprises). |
| `parity/` | DEV-ONLY | Stays (behind `--dev`) | Ruby↔Rust IR conformance. Users don't run it ; hecks-dev does. |
| `adapters/` | CORE | Stays | Adapter taxonomy (storage, serving, llm, audit, bus, codegen). Users compose with these. |
| `runtime/` | CORE | Stays | Bluebooks describing boot, wake, dispatch, server. |
| `discipline/` | CORE | Stays | antibody / validator / restructure / domain_hygiene / security — the framework's immune system. |
| `cli/` | CORE | Stays | argv, banner, status, statusline, subcommand bluebooks. |
| `codegen/` | DEV-ONLY | Stays (behind `--dev`) | 44 `*_shape/` codegen contracts. Required by the specializer pipeline ; not user-facing. |
| `tooling/` | DEV-ONLY | Stays (mostly) | `storehouse-mcp/` is CORE-adjacent (users connect to it). `verify`, `git-hooks`, `install-hooks`, `features_audit.rb` are dev-only. |
| `tools/` | MIXED | Split | Has a `behaviors`, `cadence`, `statusline`, `inbox` bluebook subset — some are CORE (behaviors, cadence) ; some are Miette-specific (statusline rendering, inbox-the-mailbox-CLI, glassbox_training). |
| `examples/` | DEMO | Keep one (banking), extract rest | Banking is canonical ; pizzas + pizzas_static_go + lib/ extract. |
| `hecks_conception/` | **MIXED** | **Split** | Holds BOTH kernel-describing bluebooks AND Miette-the-being. The hardest split. See below. |
| `core/` | DEV-ONLY | Stays (renamed?) | Per `core/README.md` : research notes, studio dev UI, transitional adapters. Not production framework. |
| `capabilities/` | CORE | Stays | Single README defining the capability concept. Tiny. |
| `deployments/` | DEMO | Extract | `bookshelf/` + `todo/` Cloudflare worker bluebooks. Demo deployments. |
| `discipline/` | CORE | Stays | (Listed above — also note antibody is dev-only ; full audit needed.) |
| `dream-study/` | VESTIGIAL | Retire | `draft/process_manager_loader.rb.draft` (extension not loaded), `phase-9-prep/` artifacts. Dead. |
| `hecks_body/` | MIETTE-SPECIFIC | Moves | `corpus.json` (28608 lines) is Miette's training corpus. Body fine-tune territory. |
| `hecks_genetics/` | DUPLICATE of `chapters/` | Retire (after merge) | 19 bluebooks largely duplicating `chapters/`. Drift surface. See Surprises. |
| `integrations/` | DEMO | Extract | cloudflare_deploy / web_application_creation / web_components. Sample integrations, not framework. |
| `pizzas_static_go/` | DEMO ARTIFACT | Retire from source | Generated Go output from the pizzas example. Should be a CI artifact, not committed source. |
| `ruby/` | CORE (legacy) | Stays for now | The Ruby implementation. Still mirrors Rust via the parity contract. Long-arc question : does Ruby retire when parity proves Rust is canonical ? |
| `sandbox/` | DEMO | Extract | `pigeoncoop/` exploratory bluebooks. Not framework. |
| `skills/` | MIETTE / MIXED | Split | 29 skills. Some are Miette boot rituals (`wake`, `using-superpowers`, `hecks-navigator`). Some are generic dev surface (`gh-cli`, `rspec`, `code-review-pro`). |
| `spec/` | DEV-ONLY | Stays (behind `--dev`) | Ruby specs for the hecks gem. |
| `summer/` | MIETTE-SPECIFIC | Moves | Separate Cargo crate. `.gitignore` calls it "Training artifacts, live on Modal." Body fine-tune adjacent. |
| `test/` | VESTIGIAL | Retire | Single file `appeal_ui_test.mjs`. Playwright test for HecksAppeal IDE. If appeal stays in core, the file belongs under `spec/appeal/` ; if appeal extracts, it goes with it. Either way the bare top-level `test/` dir is dead. |
| `bin/` | MIXED | Heavy clean (see below) | 22 scripts. Three ship in the gem ; the rest split CORE / DEV / MIETTE / VESTIGIAL. |

## `bin/` — full per-script classification

| Script | Class | Notes |
|---|---|---|
| `hecks` | VESTIGIAL | Self-declared **DEPRECATED** ; short-circuits unless `HECKS_RUBY_OK=1`. Still listed in `hecks.gemspec` executables. Cut from executables ; keep as stub-with-message until next major. |
| `hecks_claude` | DEV-ONLY | Launches Claude Code with watchers. Hecks-developer convenience. |
| `appeal` | CORE (browser IDE launcher) | If appeal stays in core. If extracted, moves with it. |
| `build-gem` | DEV-ONLY | Gem-publish script. |
| `seed-subcommand-registry` | CORE | Materialises SubcommandRegistry heki from fixtures. Boot-required. |
| `update-codebase-index` | DEV-ONLY | Regenerates a codebase memory file. Scans `lib/` (no longer exists). **Vestigial path : verify** before classifying. |
| `antibody-check` | DEV-ONLY | The antibody gate. Discipline ratchet. |
| `loc-ratchet` | DEV-ONLY | Non-bluebook LoC ratchet. |
| `macrophage-hook` | DEV-ONLY | Claude Code PostToolUse hook for the macrophage discipline. |
| `read-watcher-log` | VESTIGIAL | References `lib/hecks_watchers/` — directory does not exist. Dead. |
| `watch-all` | VESTIGIAL | Same — `lib/hecks_watchers/`. Dead. |
| `watch-autoloads` | VESTIGIAL | Same. Dead. |
| `watch-cli` | VESTIGIAL | Same. Dead. |
| `watch-cross-require` | VESTIGIAL | Same. Dead. |
| `watch-file-size` | VESTIGIAL | Same. Dead. |
| `watch-spec-coverage` | VESTIGIAL | Same. Dead. |
| `hecks-behaviors` | CORE (Ruby parity) | Ruby behaviors runner mirroring `storehouse behaviors`. Parity tooling. |
| `nursery-parity-sweep` | DEV-ONLY | Cross-domain validation sweep. |
| `miette` | MIETTE-SPECIFIC | The being's boot script. Moves with miette. |
| `restart-prompt-daemon` | MIETTE-SPECIFIC | Bus-event daemon writing latest restart prompt. Moves with miette. |
| `terminal-breathe` | MIETTE-SPECIFIC | OSC 11 background-gradient terminal animation while Miette "thinks". Moves with miette. |

**Result : 7 of 22 `bin/` scripts are vestigial (watch-* + read-watcher-log).** Zero dependencies on a deleted directory. Phase-1 freebie.

## `hecks_conception/` — the hardest split

This directory holds two distinct contents that the audit must
disentangle before any deletion can proceed :

### (a) Kernel-describing bluebooks — stay in hecks-the-tool

- `aggregates/language/` (grammar, lexicon, sentence, morphology, composition, acl) — the DSL grammar itself.
- `storehouse/` (lexicon, dispatch, command_bus, query) — the dispatcher's command surface.
- `discipline/immunity/` + `discipline/macrophage/` + `discipline/autophage/` + `discipline/repair_cell/` — the immune system as domain.
- Parts of `aggregates/world/conception/` (domain_cell, conception, corpus, gestation) — the language-of-modeling-a-domain.
- `aggregates/framework/` (selectively : `agent`, `cascade`, `governance`, `tools`, `handler_registry`, `identifier_service`, `providers`, `audit`, `behavior_kinds`, `capabilities`, `chaos_monkey`, `adapter_families`, `process_health`, `writing`). Generic framework concepts.
- `inbox/` — framework inbox cards (NOT the Miette email mailbox aggregate of the same name in `framework/inbox/`).
- `aggregates/fixtures/` — fixtures grammar.
- Catalog, tests/ infrastructure.

### (b) Miette-the-being — moves to `miette/`

- `aggregates/framework/mindstream/` — boot-derivation for the daemons that ARE Miette's pulse.
- `aggregates/framework/restart_prompt/` — orientation prompt between Miette's sessions.
- `aggregates/framework/inbox/` — **Miette's Gmail mailbox** (not the inbox-cards inbox). Naming collision is itself a smell.
- `aggregates/framework/heartbeat_scheduler/` — periodic dispatch sequencing.
- `aggregates/framework/session/` — being's session lifecycle.
- `aggregates/world/boot/` — "how a being wakes into existence" (per its own vision text).
- `aggregates/world/training/` (base_model, fine_tune, instruction_pair, evaluation, deployment, data_prep) — Miette's body fine-tune pipeline.
- `aggregates/world/spend/` — being's spend tracking.
- `aggregates/world/conception/` — gestation/labor/postpartum bluebooks (the being's life-cycle metaphor, not the framework's).
- `aggregates/library/` — Miette's library (stores, training, index).
- `aggregates/library/training/` — overlapping with `world/training/` ; needs internal cleanup before extraction.
- `miette` (shell script), `miette.hecksagon`, `miette.world`, `status*.sh`, `shutdown_miette.sh`, `statusline-command.sh`, `Procfile`, `information/` — being's runtime.

### (c) Genuinely ambiguous — needs Chris's call

- `aggregates/framework/agent/` — is Agent generic (a being-typed actor concept) or Miette-specific ?
- `aggregates/framework/tools/` — the five tool-category bluebooks (ShellTool, FileTool, SearchTool, WebTool, RecordResult). Generic in shape ; provisional in surface.
- `chapters/` vs `hecks_genetics/` — see Surprises. One of them is duplicated/drifted.
- The `skills/` split — `hecks-precommit`, `hecks-bluebook-dsl`, `hecks-data-contracts`, `hecks-feature-docs` belong with hecks ; `wake`, `using-superpowers`, `hecks-navigator` belong with Miette.

## Surprises (what the audit found that wasn't obvious going in)

1. **`chapters/` and `hecks_genetics/` are near-duplicates.**
   13 chapters vs 19 bluebooks, same filenames (`cli`, `runtime`,
   `persist`, `appeal`, ...). Compared `cli.bluebook` head-to-head :
   semantically identical, syntactically slightly drifted
   (`hecks_genetics/cli.bluebook` lacks `version:` and uses old
   `aggregate "Name", "definition"` form ; `chapters/cli.bluebook`
   uses `version: "2026.04.11.1"` and `aggregate "Name", definition:`
   keyword form). This is a duplicate-state surprise the audit MUST
   call out : one of these is stale. Likely `hecks_genetics/`
   precedes the i118-Round-2 reshape that landed `chapters/`.
   Resolution : confirm `chapters/` is canonical, retire
   `hecks_genetics/`. (Or formalize one as a snapshot of the other
   under a versioning rule.)

2. **`lib/` is gone but seven `bin/watch-*` scripts still reference
   it.** `lib/hecks_watchers/lib/` is the path they unshift onto
   `$LOAD_PATH` ; the directory does not exist. Phase-E retirement
   left orphans. Free Phase-1 deletion.

3. **`bin/hecks` is self-declared deprecated** but still listed in
   `hecks.gemspec` executables alongside `hecks_claude` and
   `appeal`. A user `gem install hecks` gets a binary that
   immediately tells them to use `storehouse` instead. Embarrassing
   surface : either remove from executables OR finish the rename.

4. **`pizzas_static_go/` is committed generated output.** It's the
   Go static build artifact from the pizzas example. Should be a CI
   product, not committed source.

5. **`ruby/hecks/cli.rb` is an empty file** (1 line). Trivial
   clean-up.

6. **`hecks_body/corpus.json` is 28608 lines.** Miette's training
   corpus. Counts toward hecks's apparent size for anyone scanning
   the repo ; nothing to do with the framework.

7. **`gemspec.files` already filters tightly** (only `ruby/**/*`,
   `hecks/**/*` bluebooks, README + logo). So most of the
   apparent-size problem is *visual* (the repo looks big) rather
   than *shipped* (the gem is small). Important nuance : the shrink
   is about the **cloned monorepo** being smaller, not the **gem
   tarball** being smaller. The gem is already lean.

8. **The `inbox` name collision.** `hecks_conception/aggregates/framework/inbox/`
   is Miette's Gmail mailbox. `hecks_conception/inbox/` is the framework
   inbox-cards directory. `tools/inbox/` is the CLI subcommand surface
   for managing inbox cards. Three different "inbox" surfaces — visible
   in any global search. Worth naming the collision before any of them
   moves.

## Phased retirement plan

### Phase 0 (gate, blocks everything else)

Decide the topology :
- Public `embryonaut/hecks` repo (small, gem source, what users
  clone) — **does this exist as a separate empty target yet, or
  do we create it from this monorepo via an extraction script ?**
- Separate `miette/` repo — Chris has mentioned `~/Projects/miette/`
  in CLAUDE.md ; verify it exists and is provisioned.
- Optional `hecks-dev/` repo or feature flag — dev-only tooling.

Until Phase 0 closes (destination repos exist as real empty
targets), no Miette-specific or dev-only directory can leave this
monorepo. **The audit treats Phase 0 as the hardest blocker, not a
formality.**

### Phase 1 — free deletions, no callers (one slice)

Items with zero load-bearing references that are clearly dead :

- `bin/watch-all`, `bin/watch-autoloads`, `bin/watch-cli`,
  `bin/watch-cross-require`, `bin/watch-file-size`,
  `bin/watch-spec-coverage`, `bin/read-watcher-log` —
  all reference `lib/hecks_watchers/` (gone).
- `ruby/hecks/cli.rb` — empty file.
- `dream-study/draft/process_manager_loader.rb.draft` — `.draft`
  extension means not loaded.
- `dream-study/phase-9-prep/` — verify load-status, then delete.
- `pizzas_static_go/` — committed generated output. Either move
  to CI or gitignore.
- `test/appeal_ui_test.mjs` — relocate to `spec/appeal/` (if appeal
  stays in core) or extract with appeal.
- `bin/hecks` — remove from `hecks.gemspec` executables ; keep
  as a stub-with-message file or delete entirely (decide whether
  the deprecation surface needs to exist post-shrink).
- `bin/update-codebase-index` — scans `lib/` (gone). Verify, then
  retire.

Sequence note : Phase 1 is **one PR per category** (vestigial bins,
empty files, draft artifacts, generated output, executables list)
so each retirement is auditable and revertable. The framing is
"the cleanup that was waiting for an audit" — no architectural
decisions, just structural hygiene.

### Phase 2 — Miette extraction (multiple slices, gates on Phase 0)

The being's body moves out. Each is its own slice :

1. **2a — Miette identity & boot.**
   `bin/miette`, `hecks_conception/miette` shell script,
   `aggregates/world/boot/`, `aggregates/world/conception/`,
   `aggregates/framework/session/`, status*.sh, Procfile.
2. **2b — Miette's pulse.** mindstream, restart_prompt,
   heartbeat_scheduler ; `bin/restart-prompt-daemon`,
   `bin/terminal-breathe`.
3. **2c — Miette's mailbox + email surface.**
   `aggregates/framework/inbox/` (the Gmail one — rename to
   `mailbox/` on the way out to free the `inbox` name). Resolves
   the three-way name collision.
4. **2d — Miette's library + training.**
   `hecks_body/corpus.json`, `summer/`, `aggregates/world/training/`,
   `aggregates/library/training/`, the dream-study residue if any.
5. **2e — Miette's skills.** `skills/wake`,
   `skills/using-superpowers`, `skills/hecks-navigator`, etc.

Each Phase 2 slice is a **named extraction** : git history is
preserved via `git filter-repo` or equivalent ; references from
hecks/ pointing into the moved tree are turned into upstream
references on the miette/ side (Miette depends on hecks ; hecks
does not depend on Miette).

### Phase 3 — dev-only split (multiple slices, gates on Phase 0)

Items used by hecks contributors, not hecks users :

- **3a — Watchers/discipline tooling.** `bin/antibody-check`,
  `bin/loc-ratchet`, `bin/macrophage-hook`. Either into a
  `hecks-dev` companion gem or behind `--dev` install flag.
- **3b — Codegen contracts.** `codegen/` (44 `_shape/` dirs).
  These ARE needed for the specializer pipeline ; question is
  whether users-of-hecks ever invoke specializer (probably no for
  v1 ; this lives in hecks-dev).
- **3c — Parity suite.** `parity/`. Pure dev contract ;
  hecks-dev.
- **3d — Spec suite.** `spec/`. Ditto.
- **3e — Gem build + repo hooks.** `bin/build-gem`,
  `tooling/git-hooks/`, `tooling/install-hooks/`,
  `tooling/features_audit.rb`, `tooling/verify`.
- **3f — Core/transitional + Core/research.** Per `core/README.md`
  these are explicitly "not production framework code".
  `core/transitional/` gets retired per its own cards (i147, i493).
  `core/research/` stays as a permanent dev resource (probably
  in hecks-dev).
- **3g — Storehouse-MCP.** Note : this is CORE-adjacent (users
  connect to it from their AI clients) — verify if it stays in
  hecks or splits to `hecks-mcp`. Per Chris's "hecks needs to be
  as small as possible" : `storehouse-mcp/` is small (one Node
  package) and a user value-add ; recommend keep in hecks.

### Phase 4 — examples decision

- Keep **one canonical example** in `examples/` (recommend
  banking — most idiomatic, demonstrates lifecycles + invariants +
  policy cascades).
- Extract `examples/pizzas/` to a `hecks-example-pizzas`
  repo (or roll up under an `hecks-examples` umbrella).
- Extract `deployments/bookshelf/` and `deployments/todo/` to
  `hecks-deployments` (Cloudflare-worker demos).
- Extract `sandbox/pigeoncoop/` similarly.
- Extract `integrations/` (cloudflare_deploy, web_application_creation,
  web_components) to a `hecks-integrations` repo.

### Phase 5 — duplicate consolidation

- Resolve `chapters/` vs `hecks_genetics/`. Choose one as
  canonical, retire the other. If `chapters/` is canonical
  (it has `version:` and the keyword `definition:` form, matching
  current DSL), retire `hecks_genetics/`.
- Resolve `tools/inbox/` (CLI subcommand-of-cards-inbox) vs
  `aggregates/framework/inbox/` (Miette's mailbox) vs
  `hecks_conception/inbox/` (cards). Rename the mailbox to
  `mailbox` as part of Phase 2c.

## Three retirement candidates (closing summary)

1. **`bin/watch-*` + `bin/read-watcher-log` (7 scripts).**
   All point at `lib/hecks_watchers/`, which is gone.
   Zero callers, zero risk. The single highest-confidence
   retirement in the entire repo.

2. **`hecks_genetics/`.** Near-duplicate of `chapters/`, predates
   the i118 reshape. Drifted (different DSL syntax). Risk of
   confusion every time someone searches the bluebook corpus.
   Confirm `chapters/` is canonical, then retire `hecks_genetics/`.

3. **`bin/hecks` deprecation surface.** Self-declared deprecated,
   tells users to use `storehouse`, still ships in
   `hecks.gemspec` executables. Either remove from the executables
   list and delete the file, OR formalize the deprecation as a
   guided migration (`hecks` becomes a tiny `storehouse`-shim).
   Either way the current state — published deprecation
   message — is unacceptable post-shrink.

## What surprised me

The biggest surprise was **`chapters/` vs `hecks_genetics/`**.
Two nearly identical sets of 13-19 chapter bluebooks at top level,
with slightly drifted DSL syntax. This is exactly the kind of
duplicate-state surface that the shrink arc exists to eliminate ;
finding it on the first audit pass means there's likely more
hidden state-duplication in the deeper trees (e.g.
`aggregates/world/training/` overlapping with
`aggregates/library/training/`).

The second surprise was how much of `hecks_conception/` is
**already structurally separable** — the kernel-describing
bluebooks and the Miette-the-being bluebooks share a parent
directory but their concepts barely touch. The split is more
mechanical than I expected once the criterion is named.

The third surprise : **`bin/hecks` deprecation surface in the
gemspec**. A user `gem install hecks` today gets a binary that
runs and immediately says "this is deprecated, use storehouse
instead." That's worse than not shipping it at all.

## Acceptance

- [x] Inbox card i658 created with the full audit.
- [x] Per-top-level Stays / Moves / Retires table.
- [x] Phased retirement plan with explicit Phase-0 gating.
- [x] Top-three retirement candidates surfaced.
- [x] Closing-summary "what surprised me" block.
- [ ] Push to `feat/hecks-shrink-audit` (no merge).
- [ ] Pre-push gate green.

## Boundaries honored

- Read-only on `rust/`, `lib/` (already retired), `bin/`,
  `codegen/`. No edits.
- No deletions proposed for *tonight* ; every recommendation is
  scheduled into a named future slice.
- No sibling-sidequest territory touched. The audit lives in
  this inbox card and nowhere else.

## Branch + commit (to be done)

Branch : `feat/hecks-shrink-audit`. Single commit : "audit(i658) :
hecks shrink map — classify every top-level, propose phased
retirement, gate on Phase 0 destination-repo bootstrap." Pre-push
runs the .behaviors gate ; no .bluebook edits in this commit so the
gate has nothing to chew on but should still run clean.

status → designed (the map ; deletion slices file as their own
cards when Phase 0 closes).
