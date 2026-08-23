# Implicit command attributes

Bare `sets :field` (no `to:`) imports the owning aggregate's or entity's own
`attribute :field, Type` when the command hasn't declared one itself.

## Motivation

`sets :field` already meant "set `:field` to the argument named `:field`"
(the omittable-`to:` shorthand). The command still needed a *separate*
`attribute :field, Type` line, byte-identical to the aggregate's own
declaration, purely to accept that argument at all. Real, pervasive corpus
evidence: `Account.Open` in `examples/banking/bluebook/`
declared `attribute :number, AccountNumber` / `attribute :kind, AccountKind`
/ `attribute :daily_limit, DailyLimit`, each copy-pasted verbatim from the
aggregate's own declaration a few lines above, each immediately followed by
a matching bare `sets`.

Mirrors [S10](../dsl-work-slices.md)'s `given`-reference pattern one level
down: "a precondition shared across commands is declared once... a command
references it by name," now for attributes instead of preconditions.

## Algorithm

For each `mutation` in the command's own declared mutations:

1. If `mutation.op` is not `set`, skip it (see
   [implicit-append-fields.md](implicit-append-fields.md) for the `append`
   case).
2. If `mutation.source` (as text) is not equal to `mutation.target` (as
   text), skip it — this is not the bare, self-referential form.
3. If the command already has its own `attribute` named `mutation.target`,
   skip it — an explicit local declaration always wins, never overwritten.
4. Look up an attribute named `mutation.target` on the OWNER (the aggregate
   or entity this command is declared on). If none exists, do nothing —
   this is not an error at this stage (see "Known limitations").
5. Append the owner's attribute object to the command's own attribute list,
   **verbatim** — same type, pattern, `optional?`, and `admits`, not just
   the same name.

## Qualifies / does not qualify

| Command body | Outcome |
|---|---|
| `sets :name` (owner declares `attribute :name, Name`, command declares nothing) | Imports `attribute :name, Name` |
| `attribute :name, Name` then `sets :name` | Unchanged — explicit local wins |
| `sets :name, to: :other_name` | Not touched — genuinely different source, `mutation.source != mutation.target` |
| `sets :accepted, to: false` | Not touched — `to:` is a literal value, not a field reference |
| `sets :amount, increment: :adjustment` | Not touched — not a bare `set` op at all (an `increment` mutation) |
| `sets :field` where neither the command nor the owner declares `:field` | Nothing is imported; the command's own attribute list stays as-is (a downstream build-time gate, `AggregateBuilder#seal_mutation_targets`, refuses this separately — not this rule's own job) |

## Known limitations

**Declaration order.** The owner's own `attribute :field` must already exist
by the time this command's own resolution runs — a strictly one-pass,
top-to-bottom constraint, the same one `given`-reference and `identified_by`
already carry. Every real bluebook satisfies this for `attribute`/`sets`
(an aggregate or entity always declares its own fields before the commands
that act on them) — no known corpus violation for this specific rule (unlike
[implicit-append-fields.md](implicit-append-fields.md)'s three real
violations one level down).

## Reference implementation

`Hecksagain::Bluebook::DSL::CommandBuilder#resolve_bare_set!`
(`lib/hecksagain/bluebook/dsl/command_builder.rb`) — the owner's own
attributes are threaded in as `owner_attributes:`, set by
`AggregateBuilder#command` (passing its own `attributes`) and
`EntityBuilder#command` (same).

## Reference mirror

`rust/parser/src/parse/command.rs`, `resolve_bare_set` — `owner_attributes:
&[ir::Attribute]` threaded through `parse_body` from
`rust/parser/src/parse/aggregate.rs` and `rust/parser/src/parse/entity.rs`.
Verified byte-identical against the real corpus via
`spec/parser_parity_spec.rb`.
