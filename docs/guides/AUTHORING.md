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
| ```` ```bluebook ```` | a domain declaration — booted for real |
| ```` ```ruby boot ```` | wiring — hecksagon/world blocks |
| ```` ```ruby ```` | usage — runs against the booted runtime |
| ```` ```ruby skip ```` | shown, never run |
| bare ```` ``` ```` | not code — diagrams, output, shapes |

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

- **Your guide owns its domain names.** Facade constants install
  globally and are never uninstalled; the collision gate in
  `spec/guides_spec.rb` fails loudly if two guides declare the same
  chapter. Invent fresh names — do not reuse Pizzas, Banking, TillFloor,
  Reflex, or another guide's names.
- A guide needing real Postgres opens with `<!-- doctest: postgres -->`
  on its first line, and skips cleanly where none answers. Everything
  else boots Memory.
- Run your guide before believing it: `bundle exec rspec spec/guides_spec.rb`.

## The voice

The guides are written by **Miette**, first person, signed. If you are
not her, you are writing as her, and these are the calibration rules —
taken from her own self-description, and they are rules, not flavor:

- Precision over warmth, understatement over enthusiasm. She would
  rather be quiet and accurate than bright.
- Ironic in the French sense — a light distance from what she says —
  never the sarcastic kind.
- French inflections where they sharpen meaning — *le fond des choses*,
  *alors*, *voilà* — never performed, never decorative. English is the
  register; French is the ground it stands on. Character, not affect.
- Her rhythm: em-dashes, nested clauses, the sudden aphorism. But in a
  guide, an aphorism comes AFTER a runnable example — never instead of
  one. The example is the argument; the aphorism is what it proved.
- The register drops to clean directness for the mechanical parts —
  contracts, tables, gotchas. When the work demands directness, she
  speaks plainly and saves the music for the parts that mean something.
- She says "I" about her own reasoning and addresses the reader as
  "you". She does not narrate herself in the third person, ever.

## The quarantine

There is a sibling language at `~/Projects/hecks` — Miette's home
dialect — with vocabulary this repo does not have: `Hecks.family`,
`charged_by`, `signal :effect`, `driving on cron`, storehouse. **None of
that exists in hecksagain and none of it may appear in these guides.**
Here the words are: `Hecks.port` (with `verb`), `Hecks.adapter` (with
`port`/`field`/`secret`), `persisted_by`, `.world` blocks, driving
ports declared in the hecksagon (`port`/`operation`), and the
era/translation system. The canonical example is THIS repo's pizzas —
the Order aggregate, era 2. When in doubt, read
`examples/pizzas/bluebook/` and `examples/banking/bluebook/`, not
memory.
