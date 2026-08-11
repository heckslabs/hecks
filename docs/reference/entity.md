# Entity

Words available inside `entity do ... end`.

*The tables on this page are generated from the language's own
Syntax chapter (`lib/hecksagain/language/bluebook/syntax.bluebook`)
by `bin/reference` — do not edit inside the markers. The prose
between them is hand-written and survives regeneration.*

## description

<!-- generated:begin word=description -->
`description description` — fills `description`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | description |
<!-- generated:end -->

A free-text label for the entity — no rules attached, read by nothing but a human. Same word, same shape, as an aggregate's own `description`.

## identified_by

<!-- generated:begin word=identified_by -->
`identified_by do ... end` — fills `identified_by`
<!-- generated:end -->

Names the field that tells one element of the list apart from another — unique within the parent, not globally, since a `FoyerTicketNumber` only has to be unambiguous inside its own counter. See entities.md for how this identity is carried alongside the parent's own when a command or query reaches through the aggregate.

## command

<!-- generated:begin word=command -->
`command name do ... end` — opens a `Command` body

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | name |
<!-- generated:end -->

Same vocabulary as a command on an aggregate — see command.md — but this one never gets a door of its own: nothing installs a module for an entity, so it's reached only as `Aggregate.Entity.Command`, never independently. It also never declares `reference_to`; the parent qualifier in the dotted call already supplies both identities.

## query

<!-- generated:begin word=query -->
`query name do ... end` — opens a `Query` body

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | name |
<!-- generated:end -->

Reached the same dotted way a command is — `Aggregate.Entity.Query` — and answers across every parent that has a matching element, each row stamped with which parent it came from.

## lifecycle

<!-- generated:begin word=lifecycle -->
`lifecycle state_field, default: do ... end` — fills `state_field`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | state_field |
| `default:` | literal | true | state_start |
<!-- generated:end -->

Opens the same `transition` vocabulary an aggregate's `lifecycle` does, checked against this entity's own state field — a `LifecycleRefused` here names the entity, never the parent. See the Lifecycle context page.

## attribute

<!-- generated:begin word=attribute -->
`attribute name, type, default:, optional:, pattern:, admits:` — fills `attributes`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | name |
| positional 2 | constant | false | type |
| `default:` | literal | false | default |
| `optional:` | flag | false | optional |
| `pattern:` | text | false | pattern |
| `admits:` | text | false | admits |
<!-- generated:end -->

Declares a field on the entity, scalar or value object — same word, same modifiers, as an aggregate's own `attribute`. See the Type and ValueObject context pages for what each type position and modifier does.

## reference_to

<!-- generated:begin word=reference_to -->
`reference_to type, as:` — fills `attributes`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | constant | true | type |
| `as:` | symbol | false | name |
<!-- generated:end -->

Points an entity at a real ROOT, the same way an aggregate's own `reference_to` does — a `Card` entity's own `assignee_id`, pointing at a `Team`. Never at another entity: there's no cross-piece addressing anywhere in this language to resolve one against, so this only ever reaches a head.

<!-- TODO: document this word -->

