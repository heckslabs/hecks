# ProcessManager

Words available inside `process_manager do ... end`.

*The tables on this page are generated from the language's own
Syntax chapter (`lib/hecksagain/language/bluebook/syntax.bluebook`)
by `bin/reference` — do not edit inside the markers. The prose
between them is hand-written and survives regeneration.*

## correlates_by

<!-- generated:begin word=correlates_by -->
`correlates_by correlates_by` — fills `correlates_by`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | symbol | true | correlates_by |
<!-- generated:end -->

The dotted scalar path that ties a stream of events to one saga
instance — e.g. `:"docket.value"`, never a bare field like `:docket`.
A non-scalar key has no single unambiguous rendering to correlate on,
so the declaration is refused at load time unless it names a scalar.

## starts_on

<!-- generated:begin word=starts_on -->
`starts_on starts_on` — fills `starts_on`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | starts_on |
<!-- generated:end -->

The event that begins tracking a new instance of this saga.

## ends_on

<!-- generated:begin word=ends_on -->
`ends_on ends_on` — fills `ends_on`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | ends_on |
<!-- generated:end -->

The event that closes an instance; once it arrives, the instance
stops being tracked.

## state

<!-- generated:begin word=state -->
`state states` — fills `states`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | states |
<!-- generated:end -->

Declares one state this saga's instances may be in, repeated once per
state. Every `from`/`to` a handler's `transition:` names must appear
here, or the declaration is refused at load time.

## on

<!-- generated:begin word=on -->
`on event_type, event_type, transition: do ... end` / `on event_type, event_type, transition:` — opens a `Handler` body

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | event_type |
| positional 1 | symbol | false | event_type |
| `transition:` | pairs | true |  |
<!-- generated:end -->

Opens one handler: a leg that must arrive while the instance is in
`transition:`'s `from` state, and moves it to `to` once its `dispatch`es
run. `event_type` is usually an event name; `:refused` is the one
exception, matching a dispatched command's own refusal rather than any
event an aggregate emits — the compensating-leg mechanics live in
policies-and-process-managers.md.

