# Remove the `reference_to` keyword (self-ref + entity-root)

_Scoped 2026-06-11. The cross-aggregate `reference_to` are already gone
(Sprint 7 + tonight's MindstreamMember conversion). What remains is the
SELF-reference / entity-root form. This card is the design + migration plan ;
do NOT sweep before the successor is locked._

## Scope (verified, all projects)
~589 calls across ~136 files across 9 roots :
hecks_conception 328/60 · miette 94/42 · miette_family 27/8 · runtime 47/6 ·
tools 31/4 · discipline 29/6 · integrations 22/8 · codegen 5/1 ·
embryonaut_clients 6/1.

## Why it's a language change, not a sweep
`reference_to(Self)` is LOAD-BEARING. `command_dispatch.rs::find_self_ref_res`
reads the command's declared references to decide : (a) this command targets
an EXISTING instance (transition), not a creation ; (b) which kwarg carries
the id ; (c) for an entity command, the id is the PARENT root's id
(`agg_snake.ends_with(ref_snake)`).

The trap : the only other transition/creation signal is a NAME HEURISTIC —
`is_create = name.starts_with("Create"|"Add"|"Place"|"Register"|...)`. It
COLLIDES with transition commands : `Sprint.AddStory` starts with "Add" but
is a transition (adds a story to an EXISTING sprint). Today `reference_to(Sprint)`
overrides the heuristic and loads the existing sprint. Remove the declaration
and rely on the name, and AddStory would MINT A NEW SPRINT — a silent wrong
creation, not a red test. So the naive "change + fix tests" loop is unsafe here.

Partial successor that already exists : the i519 universal `id` key resolves
the self-ref id without needing the kwarg name. So (b) is solved. (a) and (c)
are the open problems.

## Successor options (decide BEFORE any sweep)
- **A — flip the default (recommended if we do this).** Mark creation commands
  explicitly (`creates` / `new`) ; everything else is a transition by default,
  resolved via universal `id`. Drop `reference_to(Self)` (redundant once
  transition is the default). Retires the fragile name heuristic entirely.
  Cost : correctly mark every genuine creator across 9 repos ; rewrite
  find_self_ref_res + the is_create path ; entity-root inference from nesting.
- **B — rename, don't remove.** Replace `reference_to(Self)` with a clearer
  transition keyword (`targets` / `on`). Keeps the authoritative declaration ;
  it's a rename, not a conceptual removal. Cheaper, less benefit.
- **C — keep it.** The self-ref `reference_to` is a legitimate, authoritative
  declaration. Sprint 7's real win (kill CROSS-aggregate reference_to) is
  DONE. Removing the self-ref form for cleanliness may be net-negative —
  swapping an explicit signal for a heuristic or a synonym. Honest default
  unless A's flip-the-default cleanliness is judged worth a 9-repo sprint.

## Migration plan (when A is chosen)
Do it in a **git worktree**, never the live tree — the dispatch path being
rewritten is the one every Miette tool call routes through ; a broken
intermediate would saw off the branch she's sitting on. Steps, each gated on
(full suite + behaviors 717 + integrity + golden), merged only green :
1. ADDITIVE runtime change : dispatcher resolves transition-targeting via the
   `creates` marker + universal `id`, WHILE still honouring `reference_to`.
   Both paths work. No bluebook touched yet. Prove green with both.
2. Mark creation commands (`creates`) per repo, batch by batch, validated.
3. Sweep : remove `reference_to(Self/Root)` per repo, batch by batch ; runtime
   already handles it via step 1. ~589 sites.
4. LOCK : parser rejects the `reference_to` keyword ; build the
   retire-reference-to-keyword macrophage the IR's `LegacyReferenceTo` variant
   was kept distinct FOR ; regenerate goldens.

## Bottom line
Removable, but it is a deliberate language redesign (option A), not a sweep,
and the naive approach silently breaks creation semantics. Recommend : decide
A-vs-C explicitly ; if A, execute next session in a worktree, design-locked.

---

# LOCKED : relationship-reference grammar (the Ruby convention)

_Decided 2026-06-11 with Chris. Companion to the reference_to retirement —
same relationship-grammar redesign. This is the cross-aggregate side ;
reference_to(Self) is the command-self-target side._

The qualifier IS Ruby's constant-resolution rule, applied to `has_many` /
`has_one` / `belongs_to`. The leaf is ALWAYS a root (DDD : you reference the
Head by identity, never an internal entity) ; the prefix is pure location.

| form | scope | meaning |
|---|---|---|
| `has_many Things` | current (bare) | COMPOSITION — my own internal entity, inside the boundary |
| `has_many ::Things` | top-level | CROSS-AGGREGATE — a sibling root in THIS bounded context |
| `has_many Domain::Things` | namespaced | CROSS-CONTEXT — a root in ANOTHER bounded context |

Why it's unambiguous (no name-guess, which was the whole point) : the tier is
read off the PREFIX SHAPE alone. A token before `::` is ALWAYS a domain, never
an aggregate — so the old `Plan::Story` "is Plan a domain or the Plan
aggregate?" collision is gone. bare / `::` / `Domain::` are three distinct
shapes.

DDD grounding (Evans + Vernon) : the aggregate root is the only externally
referenceable member ; cross-aggregate relationships hold the root's IDENTITY,
never a path into internals. So the leaf is never `Aggregate::InternalEntity`.

## Two invariants (the validator enforces them)
1. **`belongs_to` / outward `has_one` are NEVER bare.** You always belong to
   ANOTHER root — so they're always `::` or `Domain::`. A bare `belongs_to` is
   an error.
2. **bare is legal only when the leaf is a real internal entity.** A bare name
   that resolves to a ROOT (e.g. `has_many Story` where Story is an aggregate)
   is an error : "did you mean `::Story`?". The convention is ENFORCED, not a
   style guide — a misqualified reference fails, it does not silently resolve
   to the wrong target (the same anti-silent-resolution principle as the
   integrity gate).

## Migration (own sprint, gated, worktree)
The IR already carries `Reference.domain` (None / Some) — extend to the three
tiers. Then : parser reads tier off prefix shape ; validator enforces the two
invariants ; normalize the ~32 bare-but-cross-aggregate decls to `::` (audit
2026-06-11) ; re-qualify the lone cross-domain `Plan::Story` to the dot/
namespace form. Each step gated on suite + behaviors + integrity + golden.

---

# RESOLVED : commands don't need reference_to at all (2026-06-11, Chris)

The self-ref half of the retirement has a clean answer. A command needs ONE
bit — create a new instance, or mutate an existing one. `reference_to(Self)`
carries that bit BACKWARDS : it marks every TRANSITION (the common case), so
"create" becomes the implicit default. Marking the majority to leave the
minority implicit is why it feels redundant — it is.

**Flip the default :**
- TRANSITION is the default — a command loads its aggregate's existing record
  by the universal `id` (i519 already provides this). Self-targeting needs NO
  declaration : the command lives on its aggregate, so it targets that
  aggregate by definition. reference_to(Self) is pure redundancy → delete.
- CREATIONS declare themselves (a `creates` marker / the command that brings
  the aggregate into being). The rare case is marked, not the common one.
- ENTITY commands : the parent-root id is INFERRED from nesting (the parser
  already knows the entity's owning aggregate) → reference_to(Root) deleted too.

**The guardrail (same principle as the integrity gate) :** the create/transition
bit must be DECLARED, never GUESSED. Do NOT infer it from "does this id already
exist" (upsert) — a typo'd id on a transition would then SILENTLY MINT a new
record instead of failing. Creations declare ; transitions must find their
record or fail loud. The current `is_create = name.starts_with("Create"|"Add"
|...)` heuristic is exactly this forbidden guess (it collides on AddStory) and
is retired by the flip.

Net : reference_to retires in two complementary moves, neither needing the
keyword — (1) relationships → the bare/`::`/`Domain::` grammar [DONE for
cross-agg] ; (2) command self-target → flip-the-default + `creates` marker +
entity-parent inference [this section]. Then parser rejects `reference_to`,
macrophage keeps it dead, goldens regenerate. One worktree sprint, gated.
