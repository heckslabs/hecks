# OneOf

Words available in the OneOf body.

*The tables on this page are generated from the language's own
Syntax chapter (`lib/hecksagain/language/bluebook/syntax.bluebook`)
by `bin/reference` — do not edit inside the markers. The prose
between them is hand-written and survives regeneration.*

## member

<!-- generated:begin word=member -->
`member members` — opens a `Member` body

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | pairs | true | members |
<!-- generated:end -->

One legal value of the closed set, e.g. `member value: "small"`. Every
`member` inside a `one_of do ... end` block adds one more admitted value;
a value not named by any `member` is refused at the door.

