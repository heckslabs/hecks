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
