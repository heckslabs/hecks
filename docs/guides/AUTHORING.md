# Authoring a guide

*Not doctested — this page is about the others.*

Every other file in this folder is executable documentation: its fenced
examples are extracted and run against the real runtime by
`spec/guides_spec.rb`, and its `# =>` claims are asserted. A guide that
lies goes red. That is the whole arrangement — prose earns no exemption
from the covenant the rest of this codebase lives under.

This page records what a guide author must know: who is reading, the
harness mechanics, and the voice.

## The reader

An implementer who wants to ship something. Not a student of the
language for its own sake — someone with a real feature to build, who
needs to know what this DSL can carry, what it refuses, and what to
wire before the thing runs in front of a user. Every guide answers a
task, not just a topic: not "here is what `given` is" but "here is how
you make a rule you can trust before you ship the command that needs
it." Concepts earn their place by being load-bearing for something a
reader will actually build — a domain, an adapter, an evolution, a
check that keeps a regression out of production. Skip the tour; keep
the thing they need to get to the shippable feature without guessing.

This also decides what belongs on a page and what doesn't: a guide may
name a gotcha because it costs someone a shipped bug, but it should not
wander into design-space exploration or "here's an alternative you
could imagine" unless that alternative is a real decision the reader
has to make (Memory vs Sqlite vs Postgres genuinely is one; a
hypothetical fourth adapter isn't).

## The harness

Fences mean things (`spec/support/doctest.rb` is the source of truth):

| fence | meaning |
|---|---|
| ```` ```ruby bluebook ```` | a domain declaration — booted for real |
| ```` ```ruby boot ```` | wiring — hecksagon/world blocks |
| ```` ```ruby ```` | usage — runs against the booted runtime |
| ```` ```ruby skip ```` | shown, never run — also the tag for a diagram, output sample, or shape that isn't really Ruby, chosen over a bare unlabelled fence so it still colors on a public renderer |

Hidden setup that would clutter the page lives in an HTML comment:

    <!-- doctest:boot
    Kernel.load(...)
    -->

A guide runs as **waves**: declarations boot, the usage blocks after
them run against that boot, and a later declaration block starts the
next wave with its own boot. Locals persist across every block in the
file — write the narrative as one session, because it is one.

Claims:

- `expr   # => expected` — asserted with `==`; the expected text is
  evaluated in the guide's own binding, so literals, hashes, arrays all
  work. Assert on `.to_h` and scalar readers, never on a raw value
  object's inspect. Never assert an id you didn't choose or a timestamp.
- `expr   # ~> Klass: message text` — the expression MUST refuse, with
  that class (demodulized) and that substring. Refusals are half the
  language; a guide that never shows one is teaching half of it.
- Both markers must sit on a single-line expression — the transform
  preserves line numbers, so a failure names your actual line.

Rules that keep the suite honest:

- **Use the real corpus — do not invent a domain.** `examples/pizzas`
  and `examples/banking` are what every guide teaches from now:
  `Kernel.load` the real bluebook file the same way
  `docs/guides/verification.md` or `docs/guides/schema-evolution.md`
  does, and dispatch/query real constructs. If neither domain currently
  has the shape or feature your guide needs, **extend banking with it**
  — a real, sensible addition a bank would plausibly make (see the
  `OnboardingCase`/`Onboarding` saga and `ScheduledPayment`'s retry
  mechanism for two worked examples of this, both added specifically to
  cover guide content that used to be fictional) — rather than
  reaching for a fictional stand-in. The one exception: content that is
  deliberately *invalid* (a malformed declaration proving a build-time
  refusal, an unreachable lifecycle state proving a `bin/model_check`
  finding, or a controlled multi-version diff that would mean minting a
  fake historical era onto real, settled data) cannot be expressed in a
  domain that must stay valid and golden — that stays a small,
  explicitly-labelled throwaway fixture, torn down inside the guide
  itself, with prose saying plainly why it isn't the real corpus (see
  `docs/guides/lifecycles.md`'s and `docs/guides/verification.md`'s own
  model-check fragments, or `docs/guides/schema-evolution.md`'s
  scaffold-walkthrough fixture, for the pattern).
- A guide needing real Postgres opens with `<!-- doctest: postgres -->`
  on its first line, and skips cleanly where none answers. Everything
  else boots Memory.
- Run your guide before believing it: `bundle exec rspec spec/guides_spec.rb`.

## The reference

`docs/reference/` is generated from the language's own Syntax chapter by
`bin/reference`, and it carries examples under the same harness the
guides do — with two rules the guides do not have.

- **Every live word carries a running example, in its own `## <word>`
  section.** `bin/doc_coverage` refuses a tree where one does not, and
  the pre-push hook runs it. A word that cannot be exemplified is a
  finding, not an exception: implement it, refuse it at build (and
  document that refusal with a `# ~>` marker, the way `cursor` does), or
  mark it non-live in `syntax.bluebook`. Do not weaken the gate.
- **All declarations go in the page preamble** — the hand-written prose
  between the page's generated lede and its first word heading.
  `Doctest::Session#waves` reboots into a FRESH registry on any
  declaration that follows a usage block, so a `Hecks.bluebook` or
  `Hecks.hecksagon` inside a word's section silently throws away the
  domain every section above it was written against. One boot per page;
  each section then carries a `​```ruby` fence proving its own word.
- Prefer the real corpus. A page that loads `examples/banking` invents no
  chapter name and installs no new constants, which is what keeps 19
  pages and 14 guides sharing one process safely. Declare a chapter of
  your own only for a word nothing ships uses — and then say so in the
  preamble, because that absence is itself worth knowing.
- Sections run top to bottom against one boot, so a section that changes
  state changes it for every section below. Put it back if it matters
  (`docs/reference/query.md`'s `where` suspends a customer and reinstates
  it for exactly this reason).
- Chapter names are claimed once across the guides AND the reference
  together — `spec/support/doctest_names.rb` enforces it, because
  `Facade::Surface.install` puts both chapter and bare aggregate names on
  `Object` and never removes them.
- A claim marker must sit on a single-line expression. Assign to a local
  first rather than wrapping a call across lines.
- Run the reference before believing it:
  `bundle exec rspec spec/reference_doctest_spec.rb`, then
  `./bin/doc_coverage`.

## The voice

Purely technical. No narrator, no first person, no signature. State
what a construct does and what it refuses; back every claim with a
runnable example. Address the reader as "you" for instructions
("declare a value object"), never as a character speaking to them.
Cut any sentence that exists for tone rather than information.

## The quarantine

There is a sibling language at `~/Projects/hecks` with vocabulary this
repo does not have: `Hecks.family`, `charged_by`, `signal :effect`,
`driving on cron`, storehouse. **None of that exists in hecksagain and
none of it may appear in these guides.**
Here the words are: `Hecks.port` (with `verb`), `Hecks.adapter` (with
`port`/`field`/`secret`), `persisted_by`, `.world` blocks, driving
ports declared in the hecksagon (`port`/`operation`), and the
era/translation system. The canonical example is THIS repo's pizzas —
the Order aggregate, era 2. When in doubt, read
`examples/pizzas/bluebook/` and `examples/banking/bluebook/`, not
memory.
