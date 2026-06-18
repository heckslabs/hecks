# Locked design : references-not-ids (belongs_to stores a queryable FK)

> Review/handoff artifact — becomes the `references-not-ids` card contract.
> If greenlit it's an Epic in Plan, not a committed prose doc.

## Diagnosis

`belongs_to X` / `has_one X` push a **Reference** (relationship metadata)
but synthesize **no stored attribute**. The establishing commands accept a
`*_ref` kwarg and drop it — `Lease.Grant` takes `worker_ref` but `then_set`
never stores it ; same in `Claim.Acquire`. So neither aggregate can be
queried by worker, which is exactly what the where-fan-out SEAM 3 needs.

## The fork (DECIDED : synthesize-attribute)

`belongs_to`/`has_one` SYNTHESISE a stored scalar `Attribute` (the FK id),
derived from the Reference at parse time. NOT reference-as-storage
(teaching storage/query/then_set/dump to understand references — the most
load-bearing runtime paths — for zero added expressiveness). The synthesised
attribute reuses every existing attribute mechanism unchanged. The author
still writes `belongs_to Worker` ONCE ; the attribute is a projection, not
hand-authored duplication.

## Locked API

- `belongs_to X` / `has_one X` synthesise `Attribute { name: <ref_name>,
  attr_type: <TargetAggregateName> (the aggregate, NOT a primitive), default: None, list: false, required: false }`
  IF no attribute of that name already exists (synthesise-if-absent).
- `<ref_name>` = the `as:` alias, else `to_snake_case(target)`.
- `has_many` does NOT synthesise a scalar (it is a collection ; separate).
- The FK is SET by ordinary command machinery : `attribute :<ref_name>, X`
  + `then_set :<ref_name>, to: :<ref_name>`.
- Queries filter via `where <ref_name>: :<ref_name>` (works the moment the
  attribute is stored — no query change).
- Reference metadata is UNCHANGED ; attribute + reference coexist by name.

## Verification findings (workflow wc2lg3hpc — FINALIZED)

- **Collisions : CLEAR.** Across the corpus (6 belongs_to + 4 has_one in
  5 aggregates : Claim->worker, Lease->story+worker, Plan->board+backlog,
  MergeQueue->current [+queued via has_many, excluded], demo->story), NO
  synthesized FK name collides with an existing attribute. synthesize-if-
  absent is safe.
- **attr_type : DECIDED — the TARGET AGGREGATE NAME, not String.** The
  `no_primitive_envy` validator (rust/src/validator.rs:276) forbids bare
  primitives (String, Integer, Float, Boolean, Date, DateTime, JSON) as
  attribute types — "no exemptions." So `attr_type: "String"` would fail
  corpus-wide. BUT an attribute typed with the target aggregate name is
  NOT a primitive and passes — with direct precedent : cross_gate already
  has `attribute :folder, Folder`. Synthesize
  `Attribute { name: <ref_name>, attr_type: <TargetAggregateName>,
  default: None, list: false, required: false }`. No new VO needed ; this
  IS the hand-authored FK convention.
- **Name disjointness : CLEAR.** No validator / parser / runtime assumes
  attribute-names and reference-names are disjoint (validator.rs:255-275
  is duplicate-ALIAS, reference-vs-reference only). Attribute + reference
  may share a name ; they coexist.
- **Parser insertion points :**
  - Rust : rust/src/parser.rs `absorb_belongs_to` (~488) + the has_one
    absorber — GOLDEN (codegen/parser_shape/, frag-gated). Synthesise the
    Attribute right after `agg.references.push(...)`.
  - Ruby : ruby/hecks/dsl/aggregate_builder.rb `belongs_to` / `has_one`
    (push `@references << Reference.new`) — hand-written. Add the
    Attribute alongside.
  - **Ordering (parity-critical) :** both parsers process lines in order ;
    synthesise the Attribute AT THE MOMENT the belongs_to/has_one line is
    absorbed, so the synthesised attr lands at declaration order in
    agg.attributes identically in both targets. Do NOT batch-append at end.

## Phasing

1. **belongs_to/has_one synthesise the stored scalar** — both parsers
   (Ruby + Rust, frag-gated), IR, dump. Gate : full parity + cargo green
   corpus-wide. THE build ; everything else is small.
2. **Sweep Lease + Claim** — `worker_ref`->`worker`, `story_ref`->`story`,
   add `then_set`, add `HeldByWorker` queries (where worker: :worker,
   state: active|held). Overlaps `retire-ref-suffix-attrs`.
3. **SEAM 3 driven adapter** — the where-fan-out payoff (capability already
   shipped : keystone 5337aabc + Route B 497f72a9) :
   ```
   driven on "Conductor::Worker.WorkerDied" do |event|
     dispatch "Conductor::Lease.Reclaim",
              for_each: { from: "Conductor::Lease.HeldByWorker", where: { worker: "{id}" } },
              id: "{worktree_path}"
     dispatch "Conductor::Claim.Expire",
              for_each: { from: "Conductor::Claim.HeldByWorker", where: { worker: "{id}" } },
              story: "{story}"
   end
   ```
   ({id} = the WorkerDied event's aggregate_id = worker_id).

## NOT closed by this

SEAM 1 (volunteer auto-select "next claimable story") is a cross-aggregate
ANTI-JOIN : `Story where untasked AND no held Claim`. The not-exists is not
where-fan-out ; it needs a `Story.Claimable` query with cross-aggregate
negation. Separate, harder gap — flag, do not fold in.

## Precision note (why a fresh context)

This is corpus-wide-parity-gated two-parser frag work. Phase 1's risk is a
silent byte miss in a frag that a fixture won't catch — only the full
parity run will. Best executed with byte-precision fresh, not at the tail
of a long session.
