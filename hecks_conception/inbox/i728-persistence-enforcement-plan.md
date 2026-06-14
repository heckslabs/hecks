# Persistence enforcement plan — steps #7 (migration) + #5 (flip)

The concrete plan for the last two persistence steps, with the central
decision RESOLVED (Chris, 2026-06-14). Supersedes the open questions in
ethereal-painting-hamster.md and the i728 card's sequencing.

## Resolved decisions

**Where persistence is declared (locked, i728 DESIGN UPDATE).** The ADAPTER
(`adapter :heki` / `:memory` / `:sqlite`) is declared in the HECKSAGON. The
`.world` supplies CONFIG only (the heki dir). A `.world` heki block is INERT
unless the hecksagon declares `adapter :heki`.

**Unwired = deployment decides (CHOSEN over strict-everywhere / memory-
everywhere).** The `.world` carries a strictness flag :
- **Non-strict (default)** — a fresh / standalone / example bluebook with no
  wired adapter defaults to `Backend::Memory`. "It just works."
- **Strict (the CONCEPTION deployment)** — an unwired domain is a BOOT ERROR.
  Every domain in Miette's live deployment must be self-aware about storage
  (Decision 1). No accidental memory for aggregates that hold her memory.

This reconciles Decision-1 (error mode) with the DESIGN-UPDATE (memory
default) : memory-default for ad-hoc bluebooks, error-mode where her real
store lives.

## #5 — the mechanism (build FIRST, strict OFF, nothing breaks yet)

1. **General `adapter :memory` selection.** Mirror `apply_sqlite_persistence`
   (now per-context, i735) : for aggregates whose hecksagon declares
   `adapter :memory`, build the explicit `Backend::Memory` (step-1 variant).
   Today this is UNWIRED — `new_memory` is only called in unit tests, so
   `adapter :memory` is inert and falls through to the implicit heki-default.
   This is the keystone : `:memory` must actually select memory.
2. **World-heki INERT without `adapter :heki`.** `apply_per_domain_world_dirs`
   (world/attach.rs) today activates a world heki dir by CATEGORY regardless
   of the hecksagon. Gate it on the owning hecksagon declaring `adapter
   :heki` (per the locked model). No adapter → the world block is config for
   nothing → the domain takes the deployment default.
3. **Deployment strictness switch.** A `.world` flag (shape TBD, e.g.
   `persistence do strict true end`). Read at boot ; threads into resolution.
4. **Resolution rewrite (the heart of it).** Replace the implicit
   heki-default in `boot_with_data_dir` : an aggregate's backend resolves
   from its hecksagon's declared adapter (`:heki` → heki at the world dir ;
   `:memory` → Backend::Memory ; `:sqlite` → the i735 path). UNWIRED →
   `Backend::Memory` in non-strict, BOOT ERROR in strict. Per-domain, not
   global.
5. **Remove the parser normalization.** `hecksagon_parser.rs:156-157`
   (`if hex.persistence.is_none() { = Some("memory") }`) — delete it. `None`
   means UNWIRED (resolved at boot per the switch), not silently "memory".
6. **The is-wired check (strict mode).** Wired = the hecksagon declares
   `:memory` / `:heki` / `:sqlite`. None → error in strict. The behaviors
   runner's `boot_in_memory` (step 4) FORCES memory and bypasses the strict
   check (the harness chose) — so the corpus keeps running even though its
   domains are unwired.

## #7 — the migration (wire the conception's persisting domains)

1. **Precise inventory.** Classify every conception domain (~129) :
   - HOLDS Miette's durable state (organs : heart/breath/awareness/memory/
     persona/…, plan, framework that persists) → wire `adapter :heki`.
   - Ephemeral / compute / pure-projection → wire `adapter :memory`
     (explicit, honest about being transient).
   - Already wired (~16 `:memory`, ~5 `:heki`) → leave / verify.
   (Rough today : ~100+ on the implicit default — these get classified.)
2. **Wire the hecksagons.** Add `adapter :heki` (or `:memory`) to each
   domain's companion hecksagon ; create a minimal one where absent. Edit,
   don't regex.
3. **Point heki config at the ONE store.** The `:heki` dir resolves under
   the canonical `~/.heki/<deployment>` — this TIES INTO step D (#2,
   `resolve_info_dir` default change). #7 and step D land together : the
   adapters need a store location, and the structural cutover provides it.
4. **Flip the conception `.world` to strict.** Only after every persisting
   conception domain is wired.
5. **Examples / standalone** stay on the memory default — no wiring, they
   just work.

## Sequence

1. #5 mechanism (steps 1–6 above), strict OFF — behaviour-preserving, gated.
2. #7 migration : wire conception persisting domains to `:heki` ; land step D
   (`~/.heki/<deployment>` store) with it.
3. Flip conception `.world` to strict.
4. i735's per-domain resolution already removed the global apply — reuse it.

## Verification gate (must pass before strict ships)

- Cold-boot persistence-recovery (organs + plan round-trip across a restart
  from the consolidated store).
- Full behaviors corpus green (runner forces memory, bypasses strict).
- `adapter :memory` actually selects `Backend::Memory` (new test).
- A world heki block with NO `adapter :heki` is INERT (new test).
- In a STRICT world, an unwired domain → boot error (new test).
- In a NON-strict world, an unwired domain → memory, no error (new test).
- Full `cargo test` green ; no warnings.

## Open shape questions (resolve at implementation)

- The `.world` strictness flag syntax (`persistence do strict true end` ?).
- Whether `adapter :memory` config needs any options (probably none).
- Migration volume : if ~100 hecksagons is too many to hand-author, consider
  a one-time generator that emits a default `:heki` hecksagon per persisting
  conception bluebook from a classification list — contract-driven, not regex.
