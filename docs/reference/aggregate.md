# Aggregate

Words available inside `aggregate do ... end`.

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

A free-text label for the aggregate — no rules attached, read by nothing but a human.

## identified_by

<!-- generated:begin word=identified_by -->
`identified_by do ... end` — fills `identified_by`
<!-- generated:end -->

Names which unchanging field or fields say which record this is — a single path (`{ tag.value }`) reads back exactly as written, and several paths, one per line, join in declaration order (`"north:3"`). The block is never called; its source is read the same way a `given`'s is, so a path names a field with no method behind it required. Get this wrong and the aggregate either builds CRUD around something that was never more than a number, or lets two genuinely different records collide because nothing told the runtime how to tell them apart — the second `Establish` against an existing identity refuses as a duplicate, not a fresh record.

## reference_to

<!-- generated:begin word=reference_to -->
`reference_to type, as:` — fills `attributes`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | constant | true | type |
| `as:` | symbol | false | name |
<!-- generated:end -->

Points at another aggregate by id, not by object — the attribute holds a bare id string, and handing it a nested value instead is refused at the door. Mints an attribute named `target_id` by default, or whatever `as:` names.

## has_many

<!-- generated:begin word=has_many -->
`has_many type, as:` — fills `attributes`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | constant | true | type |
| `as:` | symbol | false | name |
<!-- generated:end -->

Sugar over `reference_to` — despite the plural name and plural argument, it singularizes its target and mints one scalar reference, not a list. A `has_many Studios` field reads `nil` until set, never `[]`; this language has no direct spelling for a real one-to-many yet, and reaching for `has_many` to get one just hides the gap.

## has_one

<!-- generated:begin word=has_one -->
`has_one type, as:` — fills `attributes`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | constant | true | type |
| `as:` | symbol | false | name |
<!-- generated:end -->

Sugar over `reference_to` that drops the `_id` suffix, so the field reads as a relationship (`studio`, not `studio_id`).

## belongs_to

<!-- generated:begin word=belongs_to -->
`belongs_to type, as:` — fills `attributes`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | constant | true | type |
| `as:` | symbol | false | name |
<!-- generated:end -->

An alias for `has_one` — same attribute, same `_id`-less naming, whichever name reads better at the call site.

## lifecycle

<!-- generated:begin word=lifecycle -->
`lifecycle state_field, default: do ... end` — fills `state_field`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | state_field |
| `default:` | literal | true | state_start |
<!-- generated:end -->

Opens a body of `transition` declarations naming the states this aggregate may hold and the moves between them. See the Lifecycle context page for the transition vocabulary in full.

## entity

<!-- generated:begin word=entity -->
`entity name do ... end` — opens a `Entity` body

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | name |
<!-- generated:end -->

Declares a piece owned by this aggregate, with its own commands and lifecycle. See the Entity context page.

## query

<!-- generated:begin word=query -->
`query name do ... end` — opens a `Query` body

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | name |
<!-- generated:end -->

Declares a read over this aggregate's own fields. See the Query context page for `where`, ordering, and the dotted-path rules.

## policy

<!-- generated:begin word=policy -->
`policy name do ... end` — opens a `Policy` body

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | name |
<!-- generated:end -->

Declares a reaction owned by this aggregate. See the Policy context page.

## value_object

<!-- generated:begin word=value_object -->
`value_object name do ... end` — opens a `ValueObject` body, fills `value_objects`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | name |
<!-- generated:end -->

Opens a type with no identity of its own, carrying its `attribute`s and `invariant`s wherever it is used. See the ValueObject context page for the full vocabulary.

## command

<!-- generated:begin word=command -->
`command name do ... end` — opens a `Command` body

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | name |
<!-- generated:end -->

Opens what this aggregate may be asked to do — what it needs, what it refuses, and what it emits. See the Command context page for the full vocabulary.

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

Declares a field, scalar or value object. `pattern:` checks a String attribute against a regex the moment the bluebook loads, not the day a bad value reaches production — and only admits regexes every engine reads identically (no lookahead, no `\d`/`\w`). `admits:` points a field at a closed vocabulary declared elsewhere (a `one_of` on another value object) rather than restating its members, so two fields can't drift out of sync on what's allowed. `default:` fills the field when the record is built; for a value-object-typed attribute the default must fill that type's own fields (`default: { cents: 0 }`), not a bare scalar — a bare scalar loads cleanly and then refuses every create at dispatch. `optional:` lets a caller omit the argument entirely with no refusal, distinct from `default:`, which still fills the field either way.

