# command_form.bluebook and query_form.bluebook: forms and views straight off the IR

**Status: prototype.** A working slice lives at `lib/hecksagain/forms/`,
demoed by `bin/present` against the banking example. This records the
design, what it deliberately does and doesn't do yet, and the path to
making these real words in the language rather than the ordinary Ruby DSL
they are today.

**Two words, not one.** This used to be pitched as a single future word,
`presentation.bluebook`. Renamed on purpose: a command and a query are
different declarations with different shapes (a command is a POST and a
form; a query is a GET and a view), and naming them separately —
`command_form.bluebook` for the one, `query_form.bluebook` for the other —
says that up front instead of hiding it behind one umbrella word. A third,
`report_form.bluebook`, names where a chapter's cross-aggregate `report`
would eventually get the same treatment — see "Reports and read models are
not wired" below; nothing renders one yet.

## The idea

Every command already declares everything an HTML form needs — its
attributes, their types, their patterns, their closed sets, which role may
call it, what it emits. Every query already declares everything a filter
view needs. None of that has ever been read as UI before; the language just
sits there, fully structured, unused for this. `command_form.bluebook`
reads a command and renders an HTML `<form>`; `query_form.bluebook` reads a
query and renders a GET view. **One rule, applied uniformly** — not a page
authored per aggregate, not a template per command. A command or query
gains a form the moment it's declared, and loses nothing when it's
renamed, because nothing downstream was hand-written against its old name.

## Content negotiation by file extension

The mechanism is the one the user recalled from prior experience: change the
extension on a route, get a different representation of the same thing.

```
GET  /Banking/Account/Overdrawn          → the query's own shape, as JSON
GET  /Banking/Account/Overdrawn.html     → the query's filter view + results
GET  /Banking/Account/Debit              → the command's own shape, as JSON
GET  /Banking/Account/Debit.html         → the command's form
POST /Banking/Account/Debit.html         → submit the form (dispatches, then redirects)
POST /Banking/Account/Debit              → submit as JSON (dispatches, answers 201/422 JSON)
GET  /Banking/Account/a1.html            → one record's state + its next legal commands
GET  /Banking/Account/a1                 → the same record, as JSON
GET  /Banking/Account.html               → every Account + a "+ Open" link
```

One route, two representations. `.html` is `command_form.bluebook`/
`query_form.bluebook`'s whole job; the bare/`.json` path is not a
pre-existing API this project already had (there wasn't one) — it's the
necessary other half of "changing the format changes the representation,"
built alongside so the mechanism is real rather than illustrated by one
branch of an if.

## What "excellent HTML" means here

Not a framework, not a component library — plain, hand-rolled HTML5, in the
spirit of the rest of this codebase (no ERB, no template engine anywhere in
the repo; see `lib/hecksagain/forms/html.rb`'s own note). Concretely:

- **Semantic, accessible markup.** Real `<label for>`, `<fieldset>`/`<legend>`
  for a value object's own fields, `aria-describedby` linking a field to its
  help text, `aria-live` on the money preview, `role="alert"` on errors,
  visible focus rings, a `required` attribute and a visible `*` wherever a
  command actually requires the field (not decoration — read straight off
  `IR::Attribute#optional?`).
- **Progressive enhancement, not a requirement.** Every form is a plain
  `method=post`/`method=get` HTML form; it works with JavaScript disabled.
  The ~20 lines of vanilla JS in `page.rb` (copy-to-clipboard, a live
  cents→dollars preview) are decoration on top, never load-bearing.
- **Sticky, honest error handling.** A rejected submission re-renders the
  *same* form, at the *same* URL, with the values the caller actually typed
  still in place and the domain's own refusal message shown verbatim
  (`InvariantViolation`, `GivenNotMet`, whichever class actually fired) — see
  the caveat below on where this is honest and where it can't be more
  precise yet.
- **An Inspect panel on every command form and query view** — the equivalent
  `curl`, the exact field paths, the command's or query's own declaration as
  JSON (`command.to_h`/`query.to_h`), which events it emits, what its
  `given`s are and what happens if they don't hold. This is the "supply
  anything that might help a feature developer" half of the ask: a feature
  developer looking at a rendered form should be able to read straight off
  the page what the wire protocol underneath it actually is, with no need to
  go spelunking through the bluebook source to find out.
- **A record's own page is lifecycle-aware.** `/Banking/Customer/c1.html`
  only offers `Suspend` and `Close` when the customer is `active` — never
  `Reinstate`, which only applies `from: "suspended"`. This is computed the
  same way `Rules#admissible_transition` computes it at dispatch time
  (`aggregate.lifecycle.transitions_for(command)`), read here instead of
  guessed, so a link on the page is never one that would only refuse.

## Parameterized queries get links, not just forms

This was added mid-design, and it changes the query view's shape: **a
query is a GET, and a GET is inherently a URL** — so every query view leads
with a canonical, bookmarkable link template before it ever offers a form:

```
GET /Banking/Account/Overdrawn.html?floor.cents={floor.cents}&floor.currency={floor.currency}
```

And any parameter that names a **closed set** — an enum, a `one_of`, an
`admits:` — renders as literal, clickable `<a href>` links up front, one per
member, with no form to fill in for the common case ("show me the disputed
ones"):

```html
<div class="example-links">
  <a href="?direction=credit">Direction: credit</a>
  <a href="?direction=debit">Direction: debit</a>
</div>
```

Capped at the first closed-set parameter, deliberately — a second one would
mean a cross product of links, which reads as noise rather than help; a
query with more than one enum parameter is still fully reachable through the
ordinary filter form underneath. A free-form or reference-typed parameter
(an id, an amount) still needs the form — there's no finite set of links to
offer for "which account."

## The field-shape mapping

`lib/hecksagain/forms/field_shape.rb` is the one place `IR::Attribute`
becomes an HTML input shape — shared by both words equally, since a
command's own attribute and a query's own parameter resolve to the exact
same shape. It's the piece the prior prototype in this repo
(`embryonaut_console`'s `ui_schema.rb` + `presentation.yml`, vendored
under `deploy/embryonaut/.aws-sam/build/...` — see the survey that grounded
this design) fell short of: everything that wasn't a number or a
closed-set VO fell back to `<input type="text">`, even when a `pattern`
plainly named an email address.

| Declared shape | Rendered as |
|---|---|
| `pattern` containing `@`, or a name matching `/email/i` | `<input type=email>` |
| `pattern` matching `https?`, or name matching `/url\|uri\|website\|link/i` | `<input type=url>` |
| name matching `/phone\|tel/i` | `<input type=tel>` |
| `Integer` / `Float` | `<input type=number>`, step `1` / `any` |
| `TrueClass` / `FalseClass` | checkbox, with a hidden `0` twin so an *unchecked* box still submits a value |
| same-attribute `one_of` (≤4 members) | radio group, at the VO's own discriminant path (`kind.name`, not bare `kind`) |
| same-attribute `one_of` (>4 members) | `<select>`, same path rule |
| `admits:` (a set declared elsewhere) | radio/select the same way, unwrapped through the attribute's *own* value-object shape if it has one — the SET and the WIRE SHAPE are resolved independently, because they can be declared in different places |
| `{cents, currency}`-shaped value object | a `cents` number input (labelled "in cents", with a live "= $10.50" preview) + a plain currency text field — never a fabricated currency dropdown; nothing in the bluebook enumerates currencies, so nothing here invents a list |
| single-attribute value object (`EmailAddress{address}`, `CustomerNumber{value}`) | unwrapped to the *inner* attribute's own shape, at the dotted path (`email.address`) — the [[feedback_name_the_scalar_field]] rule, applied to a form the same way it's applied to Ruby call sites |
| any other multi-attribute value object | a `<fieldset>`, one input per field |
| `reference_to` | `<select>` populated from the target aggregate's real records (id → id, capped at 200) — falls back to a plain text id input if the repository isn't reachable, never a 500 |
| `list_of` | a textarea, one item per line; a multi-field element is read as one JSON object per line — the honest fallback where a second widget wasn't built |

Every path is a **dotted field path** — `email.address`, `amount.cents`,
`kind.name` — the same convention `where(:"customer.status" => ...)` already
uses for a query's own cross-object clauses ([[feedback_name_the_scalar_field]]).
`params.rb`'s `Params.extract` walks a submission back apart by that same
path, one nesting rule for a `:group`'s child and for a same-attribute
`one_of`'s unwrap alike — see its own comment for why a single nesting rule
by full path, not by tree shape, was needed (an early version nested by
`Field#kind` and silently mis-nested every unwrapped single-attribute value
object).

**Casting, not just shaping.** A web form only ever hands back strings.
`Value::Coercion#check_numeric_fields` requires an actual `Integer`/`Float`,
not a string that merely looks like one — no coercion happens at that layer.
So `Params.extract` casts against the *same* `Field` a `FieldRenderer` used
to draw the input, one reading of the IR for both jobs.

## What's shared, what's per-word

`command_form.bluebook`/`query_form.bluebook` split at exactly the point
where a command and a query actually differ — `CommandFormRenderer`
(`command_form_renderer.rb`) owns the POST form and its submit handling;
`QueryFormRenderer` (`query_form_renderer.rb`) owns the canonical link,
quick-links, and filter form. Everything else in `lib/hecksagain/forms/` is
genuinely cross-cutting and stays shared rather than being forked in two —
splitting it would mean two copies drifting, for no reader's benefit:

- `field_shape.rb` / `field_renderer.rb` — an attribute becomes the same
  input shape whether it's a command's argument or a query's parameter.
- `value_object_shape.rb` — the shared "is this VO money-shaped," "does it
  have exactly one attribute," "which member is numeric" classification
  `field_shape.rb` reads, also read directly by
  `adapters/driven/sql_query_builder.rb` for its own ORDER BY compilation —
  a command's own form, a query's own view, and a query's own SQL
  compilation all need the identical answer to the identical question.
- `reference_options.rb` — resolving a `:reference` field's `<select>`
  options against a real repository, needed by both.
- `params.rb` — the flat-web-payload ↔ nested-typed-hash conversion, needed
  by both a POST body and a GET query string.
- `record_table.rb` / `record_renderer.rb` / `index_renderer.rb` — the
  aggregate index page, a record's own show page, and the home page are
  neither a command form nor a query view; they read the repository (or
  the registry) directly and exist for every aggregate whether or not it
  declares a query at all.
- `page.rb` / `html.rb` — the shared HTML shell and escaping.
- `app.rb` — the one Rack router dispatching to all of the above by route
  shape, since a real request needs one answer regardless of which word
  eventually formalizes it.

## What this deliberately leaves out

- **Not real language syntax yet.** Neither word goes through `Hecks.*` /
  `Runtime::Registry` / `MetaValidator` the way `bluebook`/`hecksagon`/
  `world` do. `docs/guides/extending-hecks.md` is explicit that a real word
  is "a declared row before it is a line of Ruby," judged by
  `syntax.bluebook` — and this hasn't earned that yet. It's an ordinary
  Ruby DSL (`Hecksagain::Forms.configure("Name") { expose "Banking" }`,
  `lib/hecksagain/forms.rb`), one level of module state, no different in
  kind from a project's own initializer. This was tried the other way
  first — `Hecks.present` as a real collector into `Runtime::Registry` —
  and reverted: `spec/syntax_conformance_spec.rb` and
  `spec/dsl_coverage_spec.rb` both correctly refused a new word on the
  `Hecksagain` module surface with no `syntax.bluebook` row and no coverage
  example, which is exactly what those gates are for. Graduating this into
  real syntax — earning a place beside `bluebook`/`hecksagon`, as two (or
  three) separate words rather than one — is the natural next step once
  more than one domain has actually used the shape.
- **`expose` grants a whole chapter, not a command or query individually.**
  Today's `expose "Banking"` turns forms/views on for every command and
  query in that chapter at once — there is no per-declaration override yet.
  `command_form.bluebook`/`query_form.bluebook` are where that finer grain
  would live (a specific command's own label, a specific query's own
  default filter), once there's a real reason to build it.
- **Not living under `examples/`.** Every top-level entry under `examples/`
  is independently scanned as a full corpus member by `spec/corpus_spec.rb`
  and `spec/model_check_spec.rb` (`Dir.glob(examples/*)`), each expected to
  be a complete, independently model-checked domain with its own corpus
  script. The demo config is a sample of *this feature*, not a domain, so
  it lives at `lib/hecksagain/forms/examples/banking_console.bluebook`
  instead — found this the hard way, mid-build, when adding a second example
  directory turned two unrelated specs red.
- **No field-level refusal attribution.** A domain refusal is a typed
  exception carrying a rendered message (`RefusalWording`), not a structured
  `{field: "...", reason: "..."}` — so a sticky re-render shows the real
  message in a banner at the top of the form rather than guessing which
  input it was about. Worth building (parsing `RefusalWording`'s own
  templates back apart, or carrying structure through `InvariantViolation`
  itself), scoped out here.
- **Reports and read models are not wired — `report_form.bluebook` is
  named, not built.** Only aggregate-scoped `command` and `query` render. A
  chapter's `report` (a cross-aggregate read model, dispatched through
  `Dispatcher#query` differently — see `dispatcher.rb`'s own
  `domain.include?("::")` branch) is a distinct shape this pass didn't
  reach; `report_form.bluebook` is the name reserved for it, matching the
  vocabulary `command_form`/`query_form` already establish, once it's
  actually built.
- **`list_of` of a multi-field element** falls back to one JSON object per
  line rather than a real repeatable fieldset with add/remove rows — the
  honest fallback, not a silent gap; `params.rb` says so at the call site.
- **No Tailwind, no live sockets, no ERB.** The wider idea this sits inside
  (see [[project_bluebook_webframework_idea]]) reaches further than this
  pass does; what's here is the forms/views layer and the content
  negotiation underneath it, nothing about styling frameworks or
  push-updated pages.
- **Not deployed.** `bin/present` boots the banking example in memory, for
  local use — the same `webrick`/`rackup` dev-server shape `bin/console`
  and friends already use, not a production server story.

## Running it

```
bin/present            # binds :4567
bin/present -p 8080
```

Then, for example: `open http://localhost:4567/`,
`open http://localhost:4567/Banking/Customer.html`,
`curl http://localhost:4567/Banking/Account/Debit`.

To point this at a different domain, write a
`lib/hecksagain/forms/examples/banking_console.bluebook`-shaped file
(anywhere but `examples/*` — see above) declaring which chapters to
expose, and adapt `bin/present`'s own boot block (or, for a domain whose
`.hecksagon` already binds a real adapter rather than needing the
Memory rebind, just `Hecks.boot(path)` and skip the hand-rolled boot
entirely — `App.for` only needs a booted `Registry` and a configured name).

## Tests

`spec/forms/field_shape_spec.rb` — the IR → Field mapping, against
banking's real attributes (no adapter needed; `Field` is pure IR reading).
`spec/forms/app_spec.rb` — the Rack app end to end, via `Rack::Test`
and the Memory adapter: content negotiation, a full create-then-show round
trip, a sticky rejected submission, a parameterized query, lifecycle-aware
command links on a record page, 404s.
