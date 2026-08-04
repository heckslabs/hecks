# Lifecycle

Words available in the Lifecycle body.

*The tables on this page are generated from the language's own
Syntax chapter (`lib/hecksagain/language/bluebook/syntax.bluebook`)
by `bin/reference` — do not edit inside the markers. The prose
between them is hand-written and survives regeneration.*

## transition

<!-- generated:begin word=transition -->
`transition pairs, from:, from:` — fills `transitions`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | pairs | true |  |
| `from:` | text | false | from_state |
| `from:` | list | false | from_state |
<!-- generated:end -->

One legal move: `"Command" => "state", from: "state"` — the command may
fire only when the field is at `from:` (or, given an array, at one of
several), and lands at the target state after. See lifecycles.md for
enforcement, the refusal it produces, and what `bin/model_check` flags
when a transition can never fire.

