# Heki rollout (pizzas-form persistence) — state + the fan-out prerequisite

**Filed 2026-06-18 (with Chris).** Banks the heki-adapter rollout so the bulk
fan-out can resume with fresh context. The hard, irreversible work is DONE and
on `main` / pushed ; the bulk fan-out is blocked on one source-tooling prereq.

## Decisions locked (Chris, this session)

- **Form** : the FULL pizzas form everywhere — per-aggregate
  `Domain::Agg.persisted_by("Heki"|"Memory")` in the `.hecksagon`, plus a
  `.world` `persisted_by("Heki") do dir :default end` for heki domains. NO terse
  `adapter :heki` survives ; even the ~429 already-wired (domain-wide
  `adapter :heki`, e.g. the whole Bluebook context) get CONVERTED to per-aggregate.
- **Memory form** : ephemeral / compute / pure-projection domains →
  per-aggregate `persisted_by("Memory")` (NOT terse `adapter :memory`). Needs a
  `memory.adapter` declared in the root (added — see below). Memory carries no
  location, so NO `.world` block.
- **Scope** : all 4 repos — hecks_conception (priority), bin-buddy, mietteai,
  opt-website.
- **Classification** : per-domain judgment durable→heki / ephemeral→memory, read
  from each domain's vision (NOT name-guessed).
- **Gate** : `storehouse backends` diff per repo — heki domains keep their resolved
  backend + location (flip UNWIRED→wired only) ; intended heki→memory flips ONLY
  for ephemeral-classified domains, listed. Any other backend flip = automatic stop.

## DONE & durable

1. **CI green on main** (`fix/ci-drop-dead-pizzas-ruby-steps`, merged) — removed the
   dead `examples/pizzas/pizzas.rb` + `pizzas_spec.rb` CI steps (files deleted in
   `4bcdfde49`). Kept the passing top-level `Run specs`.
2. **Macrophage allows declarative config** (merged) — dropped `yml`/`yaml` from
   `bin/antibody-check` `CODE_EXTS` ; config (.yml/.yaml) joins .toml/.json on the
   allowed side. No exemption needed for CI/deploy config anymore.
3. **Keystone MERGED to main** (`feat/persisted-by-load-bearing`, `d003a633c`) —
   `persisted_by` is now load-bearing for the is-wired check. `unwired_aggregates`
   (specializer snippet `resolution_unwired_aggregates.rs.frag`) reads BOTH the
   legacy `hex.persistence` (adapter :heki) AND per-aggregate persistence-family
   bindings (persisted_by), mirroring `apply_hexagon_persistence`. Proof :
   `Pizzas::Order`/`Pizza` now read `wired`. Full `cargo test` green, no warnings,
   golden parity holds. (i745 step-4 brought forward.)
4. **Dual template proven + pushed** (`feat/heki-rollout-pizzas-form`, NOT yet
   merged) — Pizzas gains an ephemeral `Cart` aggregate wired
   `Pizzas::Cart.persisted_by("Memory")` (in-memory staging before PlaceOrder
   mints the durable Order) + `memory.adapter` in BOTH pizzas and
   `hecks_conception/aggregates/framework/adapters/`. `backends` shows
   **Cart=Memory/wired, Pizza/Order=Heki/wired** — the discriminating proof the
   BINDING (not the heki default) selects the backend. Behaviors 10/10 ; parity
   430/431 (1 pre-existing known-drift, none new). **Merge this branch first.**

## The fan-out PREREQUISITE (why it's not mechanical)

Wiring 1259 conception aggregates (359 contexts) needs a reliable
aggregate→writable-source-file map. There isn't one :

- **The IR drops source origin.** `ir.rs` `Aggregate` carries no source path ;
  `cmd_backends` boots via `load_combined_domain` which merges every file into one
  `Domain`, losing file origin. Emitting source means threading the source path
  through the loader into the backend map (+ regenerating any parity goldens).
- **Synthetic aggregates exist.** `Antibody::BranchScan`/`CommitCheck`/
  `ExemptRegistry`/`StagedCheck` appear in `backends` but in NO `.bluebook` or
  `.hecksagon` anywhere — runtime-registered, no file to add a `persisted_by` line
  to. The tooling must FLAG these (they can't be wired the pizzas way without
  separate handling).
- **Context↔file is many-to-many.** The `Bluebook` context = 234 aggregates not in
  one file ; two different `Bluebook` bluebooks exist (framework/bluebook +
  language/grammar) ; nested i118-R5 chapters. A naive grep maps only ~156/359
  contexts. No clean per-context hecksagon target without runtime truth.

## Resume plan

1. **Source tooling** (task #5) : thread aggregate→source through
   `load_combined_domain` into the backend map ; add the source path (and a
   synthetic/no-source flag) to `storehouse backends` output (or a dedicated
   query). Runtime-discovered, not grep. Same kernel-change shape as the keystone.
2. **Build the work-list** from that : group by source-file = the wiring unit ;
   list synthetic aggregates separately for Chris.
3. **Fan out** (Workflow, per source-file) : each agent reads the file's vision,
   classifies heki/memory, writes the sibling `.hecksagon` (per-agg persisted_by)
   + `.world` (heki only). Different files → no write conflicts → no worktree
   isolation needed.
4. **Gate** per repo by the `backends` diff (above). Then bin-buddy / mietteai /
   opt-website (small : 17 / 5 / 3 aggregates) — each needs its own persistence
   family + heki.adapter + memory.adapter declared (like pizzas), or share one.
5. **Synthetic aggregates** : decide with Chris — wire at their registration site
   or accept unwired.

## Provenance

Extends i728 / i745 (the persistence port + the cutover). The keystone is i745
step-4 (the persisted_by CONSULT) brought forward. `dir :default` resolves to
`miette-state/information` TODAY (no relocation ; the move to `~/.heki/` is the
later step-D flip), so wiring heki domains is behaviour-preserving now.
