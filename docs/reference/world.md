# World

Words available inside `world do ... end`.

*The tables on this page are generated from the language's own
Syntax chapter (`lib/hecksagain/language/bluebook/syntax.bluebook`)
by `bin/reference` — do not edit inside the markers. The prose
between them is hand-written and survives regeneration.*

## realm

<!-- generated:begin word=realm -->
`realm realm` — fills `realm`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | realm |
<!-- generated:end -->

Deployment identity — free text, not a closed set (`"RiveGauche"`, `"Examples"`). It is what makes a command or query's FQN addressable (`Realm::Domain::Aggregate.verb`), and `ProjectRegister` refuses to boot a project whose world has no realm, even though the meta-domain's own `Declare` command marks the field optional.

## latest

<!-- generated:begin word=latest -->
`latest latest` — fills `latest`

| argument | kind | required | fills |
|---|---|---|---|
| positional 1 | text | true | latest |
<!-- generated:end -->

Pins which `version:` of the bluebook this world treats as current — an unversioned FQN resolves to whichever version matches `latest`. Optional (a domain with no `version:` needs none), but if it names a version that disagrees with the bluebook's own, the project refuses to boot with `LatestMismatch` rather than silently picking one. None of the examples in this repository set it; every worked domain here is unversioned.

