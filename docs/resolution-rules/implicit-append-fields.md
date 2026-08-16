# Implicit append fields

Bare, self-referential fields inside an `append:` mutation
(`sets :list, append: { field: :field, ... }`) import the LIST FIELD'S OWN
ELEMENT CONSTRUCT's attribute of the same name — one hop deeper than
[implicit-command-attributes.md](implicit-command-attributes.md), whose rule
alone can't reach this case (the aggregate itself never stores the field;
only the list's own element entity or value object does).

## Motivation

Same redundancy as `implicit-command-attributes.md`, one level down: a
command building a new list element via `append:` still needed to redeclare
each field's type locally, byte-identical to whatever the list's own element
construct already declares. Real evidence: `Account.Credit` (banking) builds
a `LedgerEntry` via `sets :ledger, append: { amount: :amount, narrative:
:narrative, direction: {...} }`; `LedgerEntry` (an entity) declares
`attribute :narrative, Narrative` itself, and `Credit` used to redeclare it
verbatim purely to feed the append. The self-hosted meta-domain's own
`Keyword`/`Argument` seed-row commands are a more extreme case — EVERY field
of both (8 and 13 respectively) used to be locally redeclared this way.

## Algorithm

For each `mutation` in the command's own declared mutations where
`mutation.op` is `append`:

1. Resolve the mutation's TARGET field (e.g. `:ledger`) on the OWNER (the
   aggregate or entity this command is declared on). It must be a
   list-typed attribute (`list_of(...)`); if not, or if it isn't found at
   all, do nothing.
2. Take that attribute's own element TYPE NAME (the bare text `list_of(X)`
   names, e.g. `"LedgerEntry"`) and look it up among the owner's own
   constructs — its declared value objects first, then its declared
   entities (mirroring `AggregateBuilder#command`'s own `@value_objects +
   closed_sets + @entities` pool order). If no construct with that name is
   found, do nothing — see "Known limitations."
3. From the mutation's own field hash (e.g. `{ amount: :amount, narrative:
   :narrative, direction: { value: "credit" } }`), collect every field
   whose VALUE is a bare symbol equal to its own KEY, in the hash's own
   iteration order — `narrative: :narrative` qualifies, `direction: {
   value: "credit" }` does not (its value isn't a symbol at all), and
   `amount: :adjustment` would not (value ≠ key). Call this ordered list
   `self_ref_fields`.
4. If `self_ref_fields` is empty, do nothing.
5. Partition `self_ref_fields` into those the command ALREADY declares
   locally (`present`, in whatever order they occur in the command's own
   attribute list) and those it doesn't. If every field is already present,
   do nothing — fully explicit, nothing to resolve.
6. Compute `anchor`: the MINIMUM index among `present`'s members in the
   command's own attribute list, or (if `present` is empty — every field in
   the group is being resolved) the current length of the attribute list —
   i.e. append the whole group at the end.
7. Remove every member of `present` from the command's own attribute list.
   Because `anchor` is by construction the minimum index among the removed
   set, nothing BEFORE `anchor` shifts as a result.
8. Build the resolved GROUP, in `self_ref_fields`' own order: for each
   field, either its already-present attribute object (unchanged) or the
   element construct's own attribute of that name (looked up fresh, same
   verbatim-import as `implicit-command-attributes.md` step 5 — full type/
   pattern/optional/admits, not just the name).
9. Insert the whole group, in order, at `anchor`.

**Why step 6–9 matter, not just "append the missing ones":** the exported
IR is array-order-sensitive — an attribute's position in the list is part
of what the IR carries, not incidental. A naive `attributes << resolved`
(append at the end, ignoring existing position) only reproduces the
original order when the missing field happens to already be last. Real
evidence from building this rule: `Keyword#was` and `Argument#variadic`
(both genuinely LAST in their own append hash) round-tripped correctly
under a first, naive append-only implementation; every OTHER field in the
same two hashes did not, and was silently placed in the wrong position —
caught only by a codemod's own reboot-and-diff safety net, not by the
insertion logic itself. The group-anchor algorithm above is the fix.

## Qualifies / does not qualify

| Command body (append hash) | Outcome |
|---|---|
| `{ narrative: :narrative }`, command declares nothing locally, element declares `attribute :narrative, Narrative` | Imports `attribute :narrative, Narrative` |
| `{ amount: :amount, narrative: :narrative, direction: { value: "credit" } }`, `:amount` still explicit (different type than the element's own), `:narrative` not declared | Only `:narrative` resolves, inserted immediately adjacent to `:amount`'s existing position — group stays contiguous |
| `{ word: :word, context: :context, ... }` (8 fields), NONE declared locally | All 8 resolved as one contiguous group, in hash order, appended together (no `present` member to anchor against) |
| `direction: { value: "credit" }` | Never a candidate — the value is a literal hash, not a bare symbol |
| `amount: :adjustment` | Never a candidate — value (`:adjustment`) ≠ key (`amount`) |
| Element construct not found (see limitation below) | Nothing resolves; the command's own explicit declarations (if any) are all that's left |

## Known limitations

**Declaration order, one level deeper than `implicit-command-attributes.md`.**
The list field's own element construct (the entity or value object
`list_of(...)` names) must already be declared, among the owner's `@value_objects
+ closed_sets + @entities`, by the time THIS command's resolution runs — a
command that CREATES elements of a construct declared LATER in the same
aggregate cannot resolve against it. Three real, confirmed violations exist
in the self-hosted meta-domain (`lib/hecksagain/language/bluebook/`):
`command "Handler"` is declared before `entity "Handler"` (`reaction.bluebook`),
same for `command "Dispatch"` before `entity "Dispatch"` (nested one level
further in, same file), and `command "Member"` before `entity "Member"`
(`shape.bluebook`) — in each case the creator command lives on the OUTER
construct (comments there explain why: "an entity is never created through
its own dotted verb"), textually before the entity it creates. These three
commands still carry their explicit `attribute` declarations in the corpus;
neither Ruby nor Rust resolves them, by design — not a bug, a structural
limit of one-pass resolution. A two-pass declaration-resolution restructure
of `AggregateBuilder`/`EntityBuilder` would remove this limitation for
every resolution rule at once (this one, `given`-reference,
`identified_by`, `projected_fields`), not just this rule — named as a
candidate, not built; see the project's own session notes on this pilot
arc for the fuller writeup.

## Reference implementation

`Hecksagain::Bluebook::DSL::CommandBuilder#resolve_append_fields!` and
`#element_type_for` (`lib/hecksagain/bluebook/dsl/command_builder.rb`) — the
owner's own constructs are threaded in as `owner_constructs:`, set by
`AggregateBuilder#command` (`@value_objects + closed_sets + @entities`) and
`EntityBuilder#command` (`@owner_value_objects + @entities`).

## Reference mirror

`rust/parser/src/parse/command.rs`, `resolve_append_fields` +
`element_type_attributes` — `owner_value_objects: &[ir::ValueObject]` and
`owner_entities: &[ir::Entity]` threaded through `parse_body` from
`rust/parser/src/parse/aggregate.rs` and `rust/parser/src/parse/entity.rs`,
"declared so far" exactly like Ruby — which is why the three meta-domain
exceptions above resolve to `None` in Rust too, with no special-casing
needed; it falls directly out of the shared "so far" semantics. Verified
byte-identical against the real corpus via `spec/parser_parity_spec.rb`,
including `banking` and `bluebook_language` specifically.
