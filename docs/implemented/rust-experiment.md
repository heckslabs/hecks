# The Rust experiment: what it found, and why it's retired

> **REVERSED, 2026-08-07.** This document is a historical record of the
> FIRST Rust attempt's retirement (2026-08-03) — the decision below did not
> hold. Rust was restarted fresh on `feat/rust-projection` days later and is
> now very much alive: `rust/parser` parses `.bluebook` source directly,
> `rust/codegen`/`rust/project` generate real compiled domains, and
> `rust/src/kernel` is the hand-written runtime deployed live on AWS Lambda.
> `.githooks/pre-push`'s own header comment still cites this document as if
> the retirement held — it doesn't; there is a second, real runtime now, and
> an entire arc's worth of work (see memory `project_tables_arc_both_sides_
> read_same_table` if you have access to it, or the commit history around
> "table-unification") is built on keeping it in agreement with Ruby. The
> lesson below (declarative `.bluebook` for structure/vocabulary/rules;
> hand-written + differentially-checked for the empirical half — parsing,
> dispatch, adapter I/O) held up well through that second attempt and is
> still worth reading as-is; only the "retire it" CONCLUSION is stale.

**Status: decided, then reversed — kept for the lesson, not the conclusion.**
This records why the parallel Rust runtime and the parity discipline built
around it were removed THE FIRST TIME, what the experiment actually taught
along the way, and what that lesson does and doesn't settle going forward.
Not a eulogy — the finding was real and is worth keeping even though the
implementation it was written about came back.

## What was attempted

The arc ran in two phases, visible in the commit history as a real pivot, not
a straight line:

**Phase one: the projection thesis.** The premise was that Rust shouldn't be
a second, independently-written implementation at all — it should be
*generated* from the same self-description the Ruby side already judges
itself against (`lib/hecks/language/bluebook/`). `bin/ir_structs` and
`bin/ir_vocabulary` emitted typed Rust structs and closed-set enums straight
from the language's own declarations; `bin/ir_rust` went a rung further,
projecting a whole compiled domain as Rust *values*, sealed to its source by
SHA so a stale projection would refuse to stand in for an edited one. The
idea: `crate::ir::Aggregate` wouldn't be a port of a Ruby class, it would be
the language's own declaration, rendered in a second syntax — agreement **by
construction**, one author, nothing to drift.

**Phase two: hand-written, kept honest by checking.** The commit
`cfcafe9` — *"Rust is hand-written — the projection thesis is retired"* — marks
where that premise gave way. The parser, the dispatcher, the expression
evaluator, the adapters: all hand-written a second time, in Rust, and held to
the Ruby side not by generation but by `bin/parity` — a full-corpus,
byte-exact differential harness diffing what the two runtimes agreed on at
three stages: the IR they read, the behavior they ran, and the records they
wrote. Agreement **by checking**: two authors, a harness, and a corpus exactly
as wide as its own coverage.

The project's own docs were honest about the ratio between these two modes
from early on, and stayed honest about it — worth quoting directly rather
than restating, because it's the clearest evidence for the conclusion below:

> `bin/ir_structs` (10 structs) + `bin/ir_vocabulary` (2 enums) generate ~300 of
> ~8000 Rust lines... The value is in writing the generator, not running it:
> you cannot emit a field the language does not declare, so building one
> forces a field-by-field audit... It is only worth its weight if the ladder
> continues. Shapes were never where the money was.
> — RESTART.md, "WHAT THE PROJECTION IS ACTUALLY WORTH (do not oversell it)"

The ladder didn't continue past shapes and whole-domain values. The parser
itself — the next rung, and per that same document "where the value is" —
never finished being projected. What actually ran in Rust stayed
overwhelmingly hand-written, held in sync the expensive way.

## What it cost

122 commits touched `rust/`. A single word changed in the DSL — a new
keyword, a renamed field, a new closed-set member — could require touching,
in order: the Ruby builder, the self-hosted grammar description that judges
it, one or more of the generated Rust tables (`ir_structs.rs`,
`ir_vocabulary.rs`, `ir_dispatch_words.rs`, `ir_syntax*.rs`), the hand-written
Rust parser and dispatcher wherever they read that shape directly, a matching
Rust test, and a `spec/parity/*.json` fixture — all gated by `bin/parity`
walking the whole corpus through both runtimes and diffing every stage. That
is the opposite of what made the Ruby side of this project fast to iterate
on: a `.bluebook` file judged by its own self-hosted grammar, with nothing
else in the loop.

This wasn't a failure of execution — the two-runtime discipline caught real
bugs no single-runtime test would have (shape drift, encoding-loss families,
places both runtimes agreed *and were identically wrong*, which the project's
own docs name as the more dangerous case: agreement is not correctness). The
finding is narrower and more useful than "it didn't work": **the cost and the
value landed in different places.** The value concentrated in the small,
genuinely generatable slice — structural, closed-form, checkable by
construction. The cost concentrated in the much larger slice that resisted
generation and had to be hand-duplicated, checked only empirically, by
running both and comparing.

## The lesson

**`.bluebook` — a declarative language judged by a self-hosted grammar — is
the right tool for everything *non-empirical*: structure, vocabulary, rules,
shapes, closed sets. It was never the wrong bet.** What was wrong was
extending that same rigor to the *empirical* half — actual parsing, actual
dispatch, actual adapter I/O — by hand-writing it twice and verifying
agreement only by running both and diffing the output. That half doesn't
reduce to a declaration the way domain structure does; every attempt to force
it into that shape (the projection thesis, phase one above) stalled at
exactly the boundary where "the spec is the system" stopped being true and
real interpreter logic began.

Put differently: parity certified that two hand-written interpreters agreed.
It never made either of them cheaper to change.

## The decision

Retire the Rust runtime and the parity discipline entirely. Return to a
single, Ruby-centric implementation. The `.bluebook` DSL and the self-hosted
grammar that judges it keep doing exactly what they were already good at —
if anything, they're freed to move faster without a second runtime's
constraints trailing behind every change (the `port`/`operation` construct
built the same week this decision landed had to be deliberately kept off the
`to_h` wire contract specifically *because* Rust didn't know about it yet;
that constraint is gone now).

## What's explicitly still open, not settled by this document

- **How far "`.bluebook` for everything non-empirical" extends beyond current
  practice** — whether currently hand-coded Ruby wiring (adapter
  registration, world/hecksagon binding, possibly the DSL builders
  themselves) should move further toward declarative form. Genuinely
  undecided; not something this retrospective resolves.
- **The `to_h`/golden-IR byte-for-byte discipline**, which existed
  specifically to keep two runtimes in agreement. With one runtime, blanket
  byte-exactness has no remaining audience — but it may still be worth
  keeping as a stability contract in specific places. Decided per-change
  going forward, not by a standing rule either way.

## What this removes, mechanically

Recoverable in full from git history — nothing here is gone, only removed
from `main`:

- `rust/` — the whole Cargo workspace (`storehouse`, `sqlite`, `postgres`,
  `cli` crates)
- `bin/parity` and the `bin/ir_*` Rust-generator scripts
- The golden/export specs asserting Ruby-generator output equals checked-in
  Rust source
- `docs/porting/` — the third-runtime porting kit, entirely predicated on
  Rust existing as the reference implementation
- `RESTART.md` — a restart-prompt scratch document about continuing the Rust
  work, retired the same way this project already retired `HANDOVER.md` once
  before
