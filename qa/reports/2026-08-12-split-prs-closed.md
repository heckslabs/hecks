# Split PR closure record — 2026-08-12

Tracking issue: [#173](https://github.com/chrisyoung/hecksagain/issues/173)


## Why they're being closed

They are a **stack**: each PR's base is the previous `split/*` branch, not `main`. That is why they all report `MERGEABLE` yet none can land — the chain has no path to `main` without being merged strictly in order or rebased wholesale. The direction has since changed and nobody is driving the stack.

## What is NOT true of them

Checked before closing, so this isn't guesswork:

- **None** are merged to `main` (0 of 56).
- **None** are superseded by content already on `main` (0 of 56).
- **None** have a missing base branch.

So this is real, unmerged work being set down deliberately — not stale noise being swept up.

## Recoverable

**Closing a PR does not delete its branch.** Every `split/*` branch below still exists on the remote, and any PR here can be reopened. Nothing is destroyed by this issue's existence; if a fix below turns out to be wanted, reopen it or cherry-pick the branch onto current `main`.

## Worth a second look if anyone revisits

Several look like genuine bug fixes rather than features:

- #92 — a saga's remembered memory could mutate an already-emitted event (aliasing)
- #98 — `PolicyInterpreter#deliver_for_each` resolves the aggregate it queries (crash + record scoping)
- #100 — `IR.render_value` spells an `IR::TemplateSpec` instead of raising
- #84 — `Rendering.describe` no longer leaks a Value's raw object pointer
- #87 — `AggregateBuilder#attribute` signature regression

## The full inventory

| PR | Branch | Title |
| --- | --- | --- |
| #22 | `split/05-redirects-native-grammar` | self-hosted grammar: redirects_native round-trips through the Judge |
| #23 | `split/06-query-group-by` | query DSL: group_by aggregation |
| #24 | `split/06a-query-count` | query DSL: count aggregation |
| #25 | `split/06b-query-median` | query DSL: median aggregation |
| #26 | `split/06c-query-scope-to` | query DSL: scope_to no-op stub |
| #28 | `split/07a-entity-query-scoped-parents` | runtime: entity queries scope to their own named parent, not every parent |
| #29 | `split/07b-ir-policy-wheres-foreach-with-literals` | IR::Policy gains with_literals/wheres/for_each constructor support |
| #30 | `split/08-policy-where` | policy DSL: conditional where clauses |
| #31 | `split/09-policy-for-each` | policy DSL: for_each fan-out dispatch |
| #32 | `split/09a-policy-builder-catchall` | policy DSL: with_literals wiring, and description/condition/cross_domain stubs |
| #33 | `split/10-saga-remember` | sagas: mutable memory (remember/set/from_event) |
| #34 | `split/11-saga-given` | sagas: handler-level given |
| #37 | `split/12-saga-template-and-for-each` | sagas: template(from_pm) composition and for_each dispatch fan-out |
| #43 | `split/12c-handler-from-state-identity` | self-hosted grammar: Handler identity gains from_state.value |
| #44 | `split/12d-dispatch-position-identity` | self-hosted grammar: Dispatch identity gains position.value |
| #46 | `split/13-mutation-op-remove` | mutations: remove op |
| #48 | `split/15-mutation-op-multiply` | mutations: multiply op |
| #49 | `split/16-mutation-op-clamp` | mutations: clamp op |
| #51 | `split/17a-attribute-logged-field` | IR: Attribute gains logged: |
| #56 | `split/1855be0-a-driving-adapter-grammar` | dsl: driving-adapter grammar + raw-adapter bug fix (item 18 / 1855be0-a) |
| #57 | `split/1855be0-a3-domain-wide-adapter-defaults` | dsl: domain-wide persisted_by adapter defaults (item 1855be0-a3) |
| #58 | `split/1855be0-a4-success-failure-stub` | dsl: HecksagonBuilder success/failure async-verdict stub (item 1855be0-a4) |
| #59 | `split/1855be0-b-bare-primitive-vo-synthesis` | DSL: bare-primitive value-object auto-synthesis + collision fix |
| #60 | `split/1855be0-c-world-builder-constshim` | dsl: WorldBuilder ConstShim resolver, aggregate-qualified binding mirror (item 1855be0-c) |
| #61 | `split/1855be0-e-aggregate-level-predicates` | dsl: aggregate-level whole-record predicates (item 1855be0-e) |
| #64 | `split/1855be0-f-role-as-agent` | dsl: CommandBuilder#role structured form, role Role as: Agent (item 1855be0-f) |
| #67 | `split/1855be0-m-redirects-native-builder` | dsl: CommandBuilder#redirects_native DSL builder (item 1855be0-m) |
| #68 | `split/1855be0-n-given-guard-shapes` | dsl: CommandBuilder#given default description + named-condition guards (item 1855be0-n) |
| #69 | `split/1855be0-h-entity-reference-optional` | dsl: EntityBuilder reference_to optional:, the only syntax.bluebook hunk (item 1855be0-h) |
| #70 | `split/1855be0-i-event-sourced-sugar` | dsl: BindingProxy Aggregate.event_sourced marker verb (item 1855be0-i) |
| #71 | `split/1855be0-j-category-dsl-surface` | dsl: BluebookBuilder#category, free-form second classification axis (item 1855be0-j) |
| #72 | `split/1855be0-k-readings-bare-symbol-append` | meta_validator: Readings mutation_rows bare-symbol append crash (item 1855be0-k) |
| #74 | `split/1855be0-g-catchall-stubs` | dsl: item 1855be0-g catch-all stubs + one_of/identified_by fixes (closes 1855be0) |
| #76 | `split/24-era-check-content-matching` | runtime: era_check.rb matches a domain's own file by declared name, not filename |
| #77 | `split/25-registry-add-hecksagon-merge` | runtime: Registry#add_hecksagon merges multi-file hecksagon declarations |
| #78 | `split/26-append-log-adapter` | adapters: AppendLog, a real alias onto Heki's own append-only Journal |
| #79 | `split/27-disk-buffer-adapter` | adapters: DiskBuffer + screenshot_buffer port registration |
| #80 | `split/27a-dream-image-adapter` | adapters: DreamImage + dream_image port registration |
| #81 | `split/28-stripe-adapter` | adapters: Stripe + payment port registration |
| #82 | `split/28a-heki-dir-default-fix` | adapters: Heki#resolve_path no longer crashes on a bare dir: :default |
| #83 | `split/30-world-for-binding-generic-fallback` | bluebook: World::Binding#for_binding no longer leaks a generic setting onto an unrelated adapter |
| #84 | `split/32-rendering-describe-value-case` | rendering: Rendering.describe no longer leaks a Value's raw object pointer |
| #85 | `split/33-migration-findings-docs` | docs: what the hecks migration found -- 36 gaps hecksagain didn't have |
| #87 | `split/35b-aggregate-attribute-signature-regression` | dsl: AggregateBuilder#attribute restores its real keyword signature |
| #88 | `split/35a-category-self-hosted-round-trip` | bluebook: self-hosted grammar's own Bluebook aggregate gains category |
| #89 | `split/35-syntax-bluebook-word-registration` | self-hosted grammar: register this session's new DSL words |
| #90 | `split/36a-redirects-native-corpus-consumer` | corpus: banking.bluebook exercises redirects_native for real |
| #91 | `split/36-handler-remembers-guard-count-round-trip` | self-hosted grammar: Handler's remembers/guard_count round-trip through the Judge |
| #92 | `split/37-saga-memory-aliasing-bug` | runtime: a saga's remembered memory could mutate an already-emitted event |
| #93 | `split/39-reconstruction-category-round-trip` | bluebook: category survives the self-hosted grammar's full Judge round-trip |
| #94 | `split/40-inline-one-of-nesting-refusal` | value objects: refuse an inline one_of they cannot actually nest |
| #95 | `split/41-reference-docs-prose` | docs: prose for every new word, and a stale ir.keys example |
| #96 | `split/46-saga-runtime-state-reattach` | sagas: a handler's own guards survive the MetaValidator round-trip |
| #98 | `split/48-policy-deliver-for-each-crash` | runtime: PolicyInterpreter#deliver_for_each resolves the aggregate it queries, fixes record scoping |
| #99 | `split/46b-query-policy-self-hosted-round-trip` | self-hosted grammar: Query's count/median/group_by and Policy's where/with/for_each round-trip through the Judge |
| #100 | `split/51-template-spec-literal-rendering` | bluebook: IR.render_value spells an IR::TemplateSpec instead of raising |
