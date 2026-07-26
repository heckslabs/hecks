# Restart prompt — hecksagain

Paste this into a fresh session.

---

We are building **hecksagain** at `~/Projects/hecksagain` — Hecks rewritten with
Ruby as the source of truth. Read `README.md` first, then this.

## The thesis

In Hecks the parser is authored twice (Ruby DSL + Rust parser) and kept in step
by a parity suite. Every drift retired there was a disagreement between those
two authors. Here, **Ruby holds the semantics and Rust is a projection, except
the interpreter**. The arrow only ever runs `Ruby → IR → Rust`. Never generate
Ruby from IR.

## Standing rules — these are not negotiable

1. **Never modify `~/Projects/hecks`.** Read from it, copy out of it. Verify
   with `git diff --name-only HEAD -- rust ruby examples` before finishing.
2. **Don't hand-write what Hecks already has.** Cherry-pick the file whole and
   unedited. Three times this session I wrote something Hecks already had, and
   every time the hand-written version had a real bug within the hour.
3. **The DSL constructs the Ruby classes.** `aggregate "Pizza"` builds a real
   class as it reads ; `command` defines a real method. `Pizza.create_pizza(...)`
   is the public surface. `dispatch` is private plumbing.
4. **Zero warnings, zero failing tests.** `#[allow(dead_code)]` only by name on
   cherry-picked modules, never blanket.
5. **Tests do no IO** except `spec/adapters/` — the domain runs in memory.

## Current state (commit c3e5d6a, all green)

```
rspec                       138 examples, 0 failures, 0.085s
cd rust && cargo test --release --workspace   116 passed
bin/parity                  parsers agree · runtimes agree · records on disk
```

## Layout — Rust mirrors Ruby

```
lib/hecksagain/            rust/src/
  bluebook/                  bluebook/        what a bluebook IS
    dsl/                       parser.rs      (ruby BUILDS via DSL,
    ir/                        ir.rs           rust BUILDS via parser)
    expression/                expression/    resolver + evaluator, file-for-file
  runtime/                   runtime/
  projector/                 projector/
  adapters/                rust/sqlite/       (own crate: the port may not
    sqlite.adapter + .rb                       depend on an adapter, Cargo
  ports/persistence.port                       enforces it as a cycle)
  grammar/expression.bluebook
```

`bin/parity` has three stages: parsers agree on the IR → runtimes agree on
behaviour → both wrote the same rows.

## THE NEXT TASK: bring Hecks's Ruby DSL over

Ours is 1429 lines and hand-written. Hecks's is 7942
(`ruby/hecks/dsl/` + `ruby/hecks/bluebook_model/`). Unlike the Rust parser it is
NOT self-contained — it reaches for `Chapters`, `Generator`, `FlowGenerator`,
`BluebookVisualizer`, `Model`, `EventSourcing::ProcessManager`.

There is no bounded first step: the IR types are shared by the dispatcher,
adapters, projector AND the class construction, so it is an all-or-nothing
layer swap. Plan:

1. Copy `bluebook_model/` and `dsl/` in unedited.
2. Stub the reachable-but-unused constants — check which our grammar actually
   exercises first ; several likely never fire.
3. `Chapters` is the real decision: bring it, or provide the one entry point
   the builders call.
4. Re-layer class construction as a SUBCLASS over the ported `AggregateBuilder`,
   so the arrow stays source → class in one pass.
5. Then `parity/canonical_ir.rb` becomes available — bring it EXTENDED, not
   as-is (see below).

## Findings worth not rediscovering

- **Hecks's parity contract has a hole.** `dump.rs` excludes value-object
  invariant and derivation EXPRESSIONS, because Ruby held predicates as Procs
  and "source unrecoverable". Prism fixed that here, so our IR carries them.
  Demonstrated: invert an invariant's meaning while keeping its name and Hecks's
  contract sees no change ; ours fails. Adopt-and-extend, never replace.
- **Prism needs a real file.** A bluebook `eval`'d from a string has no source,
  so every `given` extracts empty. Specs load the real bluebook.
- **`cargo build` in a workspace with a root package builds only that package.**
  Use `--workspace` or you test a stale binary. This lied to the harness twice.
- **BSD `sed` has no `\b`.** A word-boundary rename silently changes nothing.
- **`respond_to_missing?` is auto-private** in Ruby, like `initialize`.
- **The const shim only fires for UNDEFINED constants.** Once a domain installs
  a real `Pizza`, a later `reference_to Pizza` gets that class — hence
  `Naming.demodulise`.
- **`spec/dsl_coverage_spec.rb` fails when a DSL method has no test.** That is
  deliberate. Add the example, then declare it there.

## One thing to watch

Seven refactors this session were all the same shape: something named for its
category rather than itself, or sitting apart from what it describes
(`language`→`bluebook`, `family`→`port`, `boundary`→`adapters`, declarations
beside implementations). The suite was green through every one. Tests cannot
catch this — only reading the tree and asking why a thing is where it is.
