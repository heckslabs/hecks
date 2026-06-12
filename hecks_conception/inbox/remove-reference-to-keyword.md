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
| `has_many Things` | current (bare) | SELF — something in my own boundary : an internal entity I compose, OR my own type (recursive self-reference, e.g. `Category has_many Categories`, by identity) |
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
2. **bare means SELF scope ; the error fires only on a FOREIGN root.** Three
   cases for a bare leaf :
   - resolves to an internal entity → ✓ composition.
   - resolves to MY OWN aggregate name → ✓ self-reference by identity (recursive
     tree, e.g. `Category has_many Categories`). Bare is correct here —
     referencing yourself is staying in your own boundary, not reaching for a
     sibling, so NO `::` and no `self` token.
   - resolves to a DIFFERENT root (e.g. `has_many Story` where Story is another
     aggregate) → ✗ error : "did you mean `::Story`?".
   The parser already knows the container's own name, so the "is this leaf me?"
   check is trivial and rename-proof. The convention is ENFORCED, not a style
   guide — a misqualified (foreign-root) bare reference fails, it does not
   silently resolve to the wrong target (the same anti-silent-resolution
   principle as the integrity gate).

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

---

# LOCKED : factories behind `create` (2026-06-11, Chris)

The mechanism for the command-self-target half : a `create` declaration that
is a sibling of `command`. The declaration KEYWORD carries the create-vs-
transition bit — Evans's Factory/Repository split surfaced in the DSL.

    create  "Plan"     do ... end   # FACTORY    : mint identity, new record
    command "Activate" do ... end   # TRANSITION : load by id or FAIL (default)

This retires, in one move : reference_to(Self) (the default is now transition,
no marker needed) ; the is_create name heuristic (Create/Add/Register prefix —
gone) ; AND the find-or-create UPSERT footgun.

## The strict-semantics safety rule (the whole point)
- `create` = create-or-ERROR-if-id-exists.  (NOT the current find-or-create.)
- `command` = load-or-FAIL-if-absent.       (NOT the current no-self_ref upsert.)
A mis-tagged command fails LOUD instead of silently minting/corrupting — the
same anti-silent principle as the integrity gate. Today `id_for_command` +
the no-self_ref branch do find-or-create (upsert) ; the migration must flip
both doors to strict, and AUDIT which commands currently lean on upsert
(idempotent re-Register / re-Add).

## Identity (unchanged)
`create` mints via identified_by (caller-supplied value) or the next_id
counter or the singleton fallback ; `command` resolves the target id via the
universal `id` key (i519). No new machinery.

## Open : entity creation
Adding an entity (e.g. Attachment under Story) : `create` scoped to the entity
with the PARENT root id inferred from nesting (the parser knows the entity's
owning aggregate) — the same inference that retires entity→root reference_to.
Needs a concrete rule before the sweep.

## Whole-retirement summary
reference_to retires in TWO halves, neither needing the keyword :
1. RELATIONSHIPS → bare / `::` / `Domain::` grammar  [grammar DONE for cross-agg]
2. COMMAND self-target → `create` vs `command` + universal `id` + entity-nesting
   inference  [this section]
Then : parser rejects `reference_to` ; macrophage keeps it dead ; goldens
regenerate. One worktree sprint, gated (suite + behaviors + integrity + golden).

---

# CORRECTION : reference by IDENTITY, not `id` (2026-06-11, Chris)

Domains do not reference `id`. An aggregate references another by its IDENTITY
— a TYPED value object (SprintNumber, StoryRef) — and a command targets its own
aggregate by that aggregate's declared `identified_by` field. `Sprint.Activate`
resolves its Sprint by `number` because number IS a Sprint's identity. There is
no domain-level `id`.

**Corrects the `create`/`command` mechanism above** : a `command` (transition)
resolves the target by the aggregate's `identified_by` field (number / ref /
name), NOT the universal `id`. The universal `id` (command_dispatch.rs:212,
i519) is demoted to what it is : a RUNTIME-EDGE adapter for generic cascade
callers that don't know the identity's name — below the domain, never a thing a
bluebook reaches for.

## The drift is real and measured (2026-06-11)
- 44 aggregates are `identified_by :id` (identity = a raw id, not a domain VO).
- 130 `attribute :id` declarations across bluebooks.
- The runtime accepts `attrs.get("id")` as a universal fallback — the gravity
  well that keeps pulling the domain back to id-thinking.
End-state : retire `identified_by :id` / `attribute :id` toward typed
identities (worst offenders are likely framework/tools — git, filesystem —
which are infra-ish, but the principle holds everywhere).

## Same disease as reference_to
Both are the domain reaching for a RUNTIME PRIMITIVE instead of a DOMAIN
CONCEPT : `reference_to` for "a relationship", `id` for "an identity". Same
fix : the bluebook names the concept (belongs_to / the typed identity) ; the
runtime adapter handles the plumbing beneath. They retire in the SAME sprint.

---

# RESOLVED : Plan is a Domain Module, not an aggregate (2026-06-11, Chris + audit)

Surfaced while choosing the `create` keyword : the card's example `create "Plan"`
felt wrong because you do NOT create a Plan — "we just create sprints, stories,
tasks." Chris : "Maybe Plan is a Domain Module — I don't think we have that
concept yet." Audited Plan's full surface to decide retire-vs-keep on evidence.

## The deciding question (Evans) : does a singleton aggregate guard a spanning invariant?
A singleton aggregate is legitimate in exactly ONE case — it enforces an invariant
that spans its contents (e.g. uniqueness across a registry). Otherwise it is the
bounded-context / Module masquerading as an Entity (the singleton-registry smell).

## Audit verdict : Plan is hollow (inv_4cc1e915 / 6af0cfc2 / 4e0aea5e / 6821c576)
| probe | finding |
|---|---|
| commands | ONE — `Open`. No command touches its own contents (no AddProject/SetBoard). |
| queries | zero. |
| invariants (`invariant`/`requires`/`unique`/`guard`/`state`) | **zero** — grep on the root is empty. |
| `PlanOpened` cascades / driven policies | zero. The event fires into the void. |
| callers of `Plan.Open` | zero across conception/miette/miette_family. Nothing opens a Plan. |
| `PlanOpened` in any golden | zero. |
| `plan.heki` live store | none — never instantiated at runtime. |
| back-references (Board/Project → Plan) | none. |
| `has_one Board` / `has_many Projects` | declared, NEVER populated — no command sets them. |

The one candidate spanning-invariant — one-active-sprint-per-project uniqueness —
is explicitly homed UPSTREAM on **Project** (sprint.bluebook:273), not on Plan.
So the steelman is dead : Plan guards nothing. Meanwhile the real Factories live
where the lifecycles are — `Board.Open`, `Project.Register`, `Sprint.Plan`,
`Story.Capture`, `Task.Add` — all minting independently of Plan. "The registry of
Projects" is just `Project.all`, a query, not Plan's `has_many`. And the doubling :
the *bluebook* already declares "The Planning bounded context" ; the *aggregate*
Plan re-declares it with zero behaviour.

## Decision
- **Retire the Plan singleton aggregate.** The bluebook IS the Planning module.
  Board, Project, Sprint, Story, Task, Backlog, UseCase, Epic, Demo are the
  aggregates with real Factories (`create`). Removing Plan deletes a `create`-able
  thing that was never on the create/command axis — it makes the model stop lying
  about what gets born. Validates "we just create sprints, stories, tasks."
- **"Domain Module" : born minimal, or deferred.** The bluebook already plays
  bounded-context (cross-context refs use `Domain::`). Promote Module to a
  first-class declared/queryable node ONLY when something needs to query or
  annotate the context — not preemptively. Lean : retire Plan now, let the
  bluebook stay the module ; note Module-as-first-class as deferred.

## Migration (execute FRESH, not at session-tail — same byte-precision discipline)
Small but golden-touching, so clean-headed :
1. VERIFY the rust/src wiring (main.rs / storehouse_router.rs / world/attach.rs /
   io_validator.rs matched "Plan" — confirm it's generated router registration
   that regenerates away, not hand-wiring that breaks compile).
2. Delete the `aggregate "Plan"` block from plan.bluebook (the Name VO + `Open`
   command + has_one Board / has_many Projects go with it). The bluebook stays
   named "Plan" (the bounded context) ; only the aggregate is removed.
3. Regenerate goldens ; green : full suite + behaviors + integrity + golden.
4. Confirm no view/diagram assumed a Plan root (safety grep already clean : no
   render enumerates one).
Blast radius measured SMALL : PlanOpened in zero goldens, zero behavior callers,
zero live data. Not the two-parser breadth of the reference_to sweep — a clean
single-bluebook deletion.
