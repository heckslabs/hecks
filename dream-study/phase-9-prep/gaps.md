# Phase 9 prep — runtime primitive gap list

Everything `run_statusline.rs` does that the bluebook + runtime cannot
yet express. Each row here is a hard prerequisite for the IR-walker
rewrite. Some are tractable in this branch ; others are kernel-floor
work that should land first.

## P0 — must land for full byte-identical conversion

### G1. Cross-aggregate query dispatch from inside a query

**Problem.** `Statusline.Render` needs to call `Body.GetState`,
`Heartbeat.GetCurrent`, `Mood.GetCurrent`, etc. — eight to ten named
queries against eight to ten source aggregates. Today, cross-aggregate
reads only happen from policies / process\_managers via `with_attrs
from_heki:`. Queries cannot dispatch other queries.

**Why P0.** Every render attribute starts with one of these dispatches.
Without it, the renderer has no choice but to keep reading heki paths
directly (which is exactly the leak this phase is trying to close).

**Sketch.** Extend the i101 query IR (already shipped via commit
`5635ecc3`) with a `dispatch:` directive on `attributes` blocks ; the
runtime resolves the target query against the same domain registry
the command bus uses. The `:memory` adapter handles persistence ;
bluebook never names a heki path.

### G2. Section / row IR walker

**Problem.** `cli/statusline/statusline.bluebook` already declares
three sections (`Awake`, `Sleeping`, `Minimal`) with row composition.
Nothing walks them today. The Rust renderer hand-codes the same shape.

**Why P0.** This is the actual rendering primitive. Without a walker,
"the bluebook holds the format" is fictional — the format will keep
living in Rust.

**Sketch.** Runtime accepts a `section: <name>` attribute on a query
result and emits each row in declared order, calling each row's
referenced attribute, joining with the section's separator (default
single space ; double-space delimiter for sleep narrative). Conditional
visibility predicates per row : `visible_when: predicate`,
`empty_hides: true` (the latter is FatigueState's default behaviour).

The dashboard at `capabilities/status/` (i105) needs the same primitive ;
landing one walker lights both up.

### G3. Time-driven glyph cycling — clock as a query input

**Problem.** Three glyphs cycle by wall clock : moon (8 frames /
8 secs), heart (2 frames / 666ms), bulb (4 frames / 4 secs). Today
`SystemTime::now()` is called directly in the Rust renderer.

**Why P0.** The byte-exact snapshot fixtures are pinned at known
clock readings ; the runtime needs to accept a clock reading as a
query input so tests can drive it deterministically and production
walks the real clock.

**Sketch.** New kernel-floor query `Clock.Now` (or adapter primitive
`:clock` exposing `:unix_secs` + `:unix_nanos`). The Render query
takes the reading as `attributes :clock, dispatch: "Clock.Now"` ; a
new `cycle:` operator on attributes selects from a frame table by
`(clock_value % modulo)`. Tests inject a frozen clock reading via
the `:memory` adapter.

### G4. Icon-glyph lookup operator (value\_object resolution)

**Problem.** `mood_icon_for("focused")` → "🎯". Today : a Rust
`match` arm. Tomorrow : look up the MoodState fixture row by name,
read its :icon attribute, fall back to the table's `:fallback`
when no row matches.

**Why P0.** Three tables × ~10 entries each ; the only way to keep
the icon mapping byte-stable is to walk the value\_object fixtures.

**Sketch.** New attribute decorator `via: :icon_of` (or generic
`lookup: { table: MoodState, key: :name, return: :icon }`). The
runtime resolves at query-eval time. Combined with a `fallback:`
declaration on the value\_object itself.

## P1 — tractable but optional for first cut

### G5. Format operator on Integer attributes

**Problem.** `format_beats` produces `"82.42k"`, `"1.50m"` — a tier
table with thresholds + scale + suffix + decimals. Today : a Rust
`fn`. Could either land as a runtime primitive or stay in Rust as
a formatter helper the IR walker calls.

**Sketch.** `format: { thresholds: [...], else: :raw_string }` on
attribute. If too rich, accept a small set of named formatters
(`:beats`, `:duration`, `:phase_ticks`) and inline the math.

### G6. Conditional row visibility predicates

**Problem.** Inventions row hides when count == 0 ; inbox row
hides when count == 0 ; sleep summary hides when empty or "present" ;
fatigue row hides when icon is "" ; sleep timer hides when stage
isn't REM.

**Sketch.** Two-form syntax on `row` declarations :
`visible_when: ":inventions_count > 0"` (predicate string, parsed
as a tiny expression DSL) and `empty_hides: true` (idiomatic for
the value\_object-icon-empty case). Mostly a parser + evaluator
extension on the existing section IR.

### G7. Coherence override on attribute

**Problem.** When `coherence_ok == "no"`, mood\_icon becomes ⚠.
Today : Rust mutates the icon after the lookup.

**Sketch.** Allow attributes to declare `override_when: { ... },
override_to: <value>`. Order : declaration → override applied last.
This is general-purpose ; many surfaces have similar override
patterns.

## P2 — out of scope for this branch but on the path

### G8. `:fs` adapter primitives

`/tmp/miette_minting` (existence probe) and `<info>/.last_dispatch`
(two-line read with timestamp freshness check) are filesystem
sentinels. Each becomes a tiny aggregate — `MintingFlag` and
`LastDispatch` — once `:fs` is a hexagon adapter rather than a
direct `std::fs` call. Bluebook would say `attributes
:minting_flag, dispatch: "MintingFlag.IsActive"` ; the `:fs`
adapter resolves it.

### G9. Coherence as a domain attribute

Today `status_coherence.sh` is a subprocess invoked from inside the
renderer ; it appends to `.coherence.log` and gates the mood icon.
This is policy + side-effect, not render. Migration target : a
**StatusCoherence policy** subscribes to body events and writes
`coherence_ok` onto Body ; the Render query just reads
`Body.GetCoherence`. The log-append moves into the policy's reaction
emitter. Removes the only subprocess from the renderer.

### G10. UTC ISO timestamp formatter

Currently 22 lines of inlined civil-time math (`utc_iso_now`).
Belongs to the `Clock.Now` kernel primitive — not a render concern.
Once the coherence policy moves out, this disappears too.

## Tractability summary

| Gap | Branch impact | Notes |
|-----|---------------|-------|
| G1 cross-aggregate query dispatch | **must land** | builds on i101 ; ~1 PR scope |
| G2 section/row walker | **must land** | shared with dashboard (i105) ; ~1 PR scope |
| G3 clock-driven cycling | **must land** | needs new `Clock.Now` query + cycle operator |
| G4 icon-glyph lookup | **must land** | extends value\_object fixtures with attribute lookup |
| G5 format operator | nice-to-have | could stay as formatter helper |
| G6 row visibility predicates | nice-to-have | small parser extension |
| G7 attribute override | nice-to-have | general pattern, lands cheaply |
| G8 :fs adapter | next branch | depends on hexagon adapter slate |
| G9 coherence policy | next branch | reshapes status\_coherence.sh |
| G10 UTC ISO formatter | next branch | falls out of Clock primitive |

## Top three primitives by load-bearing-ness

1. **Cross-aggregate query dispatch** (G1) — without this, every
   other piece is irrelevant ; the renderer remains a heki reader.
2. **Section / row IR walker** (G2) — the format strings have no
   home until the runtime walks the rows. Also unblocks the dashboard
   at i105.
3. **Clock-driven cycling + frozen-clock test injection** (G3) —
   the byte-exact snapshot contract is impossible without it ; the
   moon, heart, and bulb all key off wall-clock readings the test
   suite has to control.

Once those three land, G4-G7 are mechanical extensions and the rest
falls out of the next adapter slate.
