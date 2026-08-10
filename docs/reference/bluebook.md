# Bluebook

Words available inside `bluebook do ... end`.

*The tables on this page are generated from the language's own
Syntax chapter (`lib/hecksagain/language/bluebook/syntax.bluebook`)
by `bin/reference` — do not edit inside the markers. The prose
between them is hand-written and survives regeneration.*

## vision

<!-- generated:begin word=vision -->
`vision vision` — fills `vision`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | vision |
<!-- generated:end -->

A one-line statement of what the domain is for. Optional, but not empty if given — the same value-object invariant fires here as on any string field, enforced by the meta-domain that judges the bluebook itself. Stored on the chapter and readable back after boot as `Chapter.vision`.

## formerly_known_as

<!-- generated:begin word=formerly_known_as -->
`formerly_known_as formerly_known_as` — fills `formerly_known_as`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | formerly_known_as |
<!-- generated:end -->

A domain's own declared identity can change. Naming what it used to be lets the storage layer recognize its own history under the old name instead of minting a brand-new lineage from nothing — a rename, once applied, bridges the journal, the sequence, every era partition, and the domain-keyed rows in `hecks_eras`/`hecks_era_texts`/`hecks_approvals`/`hecks_attestations` onto the new name, in one transaction, the first time the domain boots under it. Optional, but not empty if given — the same value-object invariant fires here as on any string field. Stored on the chapter and readable back after boot as `Chapter.formerly_known_as`; safe to leave declared permanently, since every later boot after the bridge falls through to the ordinary already-held path.

## core

<!-- generated:begin word=core -->
`core` — fills `classification`
<!-- generated:end -->

Marks this chapter a core subdomain, in the DDD sense (core/supporting/generic). `core`, `supporting`, and `generic` all just set the one `classification` field, so calling more than one leaves whichever ran last — and, verified against the runtime, nothing else currently reads that field back. It documents intent; it gates nothing.

## supporting

<!-- generated:begin word=supporting -->
`supporting` — fills `classification`
<!-- generated:end -->

Marks this chapter a supporting subdomain. Same field, same mutual exclusivity, as `core`.

## generic

<!-- generated:begin word=generic -->
`generic` — fills `classification`
<!-- generated:end -->

Marks this chapter a generic subdomain — undifferentiated, off-the-shelf territory in the DDD sense. Same field as `core`.

## aggregate

<!-- generated:begin word=aggregate -->
`aggregate name do ... end` — opens a `Aggregate` body

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | name |
<!-- generated:end -->

Opens the thing with identity in this domain — `identified_by`, its `attribute`s, `command`s, and lifecycle. See the Aggregate reference page for the full vocabulary inside.

## report

<!-- generated:begin word=report -->
`report name do ... end` — opens a `ReadModel` body, was `read_model`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | name |
<!-- generated:end -->

Opens a read that gathers heads from several aggregates around one spine — declared at the chapter's own top level, not under any single aggregate, because no one aggregate owns it. See the ReadModel reference page for `reference_to`/`include` and the rest. Spelled `read_model` in every bluebook written before this word's rename — that spelling still boots, forever; `report` is the SME-facing word going forward.

## policy

<!-- generated:begin word=policy -->
`policy name do ... end` — opens a `Policy` body

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | name |
<!-- generated:end -->

The same word as inside an `aggregate` — a reaction to an event, `on`/`trigger` — but written here at the chapter's top level for a policy that isn't one aggregate's own business. Pizzas' `OnPizzaPaymentReceived` (examples/pizzas/bluebook/pizzas.bluebook) is a real example: it triggers `Order.Purchase` but is declared beside the aggregate, not inside it. See the Policy reference page.

## process_manager

<!-- generated:begin word=process_manager -->
`process_manager name do ... end` — opens a `ProcessManager` body

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | name |
<!-- generated:end -->

Opens a stateful saga spanning several events and commands — `correlates_by`, `starts_on`/`ends_on`, its `handler`s. Chapter-level only, like `report` and top-level `policy`, since it belongs to no single aggregate. See the ProcessManager reference page.

