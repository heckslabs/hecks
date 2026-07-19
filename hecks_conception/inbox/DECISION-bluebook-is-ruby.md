# DECISION — The Bluebook is a Ruby-embedded language. Valid Ruby is a design constraint.

**Ruled by Chris, 2026-07-18 : “I like that it's Ruby — I believe that's a design constraint.”**

## The ruling
Every `.bluebook` must be syntactically valid Ruby. The `instance_eval` DSL is not a legacy shim awaiting a “Ruby parser lift” — it is a legitimate, permanent parser, and Ruby's syntax is a FITNESS FUNCTION on the grammar : if a construct cannot be said in Ruby, find the Ruby-shaped way to say it (usually one comma away from the English).

## What the constraint buys (the ledger that argued for it)
- **Loud failure on unknown vocabulary** — Ruby executes the file ; an unknown word is a NoMethodError at load. (The silently-dropped VO invariants of 2026-07-18 were the cost of lenient text parsing ; eval never has that failure mode.)
- **A free, battle-tested reference parser** — twenty years of Ruby lexer.
- **Blocks as live behavior** — givens/invariants are real Procs on the Ruby runtime.
- **Host tooling** — highlighting, linters, editors, Rails embedding (`Hecks.boot`).
- **Discipline** — the constraint forced `belongs_to Story, from: Plan` (English AND Ruby) over the outlaw space-form ; the grammar improved by having to submit.

## What it cost tonight (and the resolutions)
- The space-form ` from Context` qualifier (Relationship chapter, 2026-06-18) was the ONLY corpus construct violating the constraint — retired same-day : demo.bluebook re-spelled `belongs_to Story, from: Plan` ; Rust `parse_from_context` reads the kwarg ; Ruby builders (`belongs_to`/`has_one`/`has_many`) grew `from:` ; Relationship vision + macrophage prose updated.
- **known_drift.txt is EMPTY — parity 387/387** across every bluebook in existence, both parsers, byte-equal canonical IR.

## Standing consequences
1. **New grammar must pass the Ruby test before it ships.** A construct unpronounceable in Ruby is a design smell, not a parser gap. (`one_of("USD","EUR")`, `one_of do member … end` — both already Ruby-shaped.)
2. **known_drift.txt stays empty.** A new entry requires Chris's explicit sign-off ; the default answer to drift is re-spelling the grammar, not ledgering it.
3. The “Ruby parser lift” retirement path is VOID. The Extraction-grammar end-state (both parsers projected from one declared grammar) remains compatible — the declared grammar simply lives inside Ruby's syntax envelope.
4. Proc-vs-string asymmetry is accepted : canonical IR carries invariant NAMES (shared truth) ; each runtime enforces predicates from its own parse.
