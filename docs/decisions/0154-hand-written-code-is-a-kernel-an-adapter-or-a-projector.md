# Hand-written code is a kernel, an adapter, or a projector

**Status:** Proposed. Names a rule the repository mostly follows and the three places it does not:
the Ruby runtime (`lib/hecks/runtime`), the host core (`rust/host/core`) and the generators
(`rust/codegen`, `lib/hecks/projections`). Nothing here is built; the first step is the scan.
Date: 2026-10-28.

## Context

Hecks is declared. A domain is a bluebook, its wiring is a hecksagon, and the rule of thumb in
`CLAUDE.md` says that anything that cannot be said in either is not Hecks code: an adapter behind
a port, or a generator, and it needs a reason. The Rust side is held to that already. ADR 0011
compiles type shapes from canonical IR and interprets dispatch behaviour through one hand-written
kernel (`rust/src/kernel`), so a new command shape is new data for the same loop, never new
control flow. ADR 0027 names canonical IR and the projector framework as the seam, and ADR 0149
split `rust/host` so the core names no driver and the era store is a port.

The user put the target in one sentence: the kernel should be the only hand-written thing outside
bluebooks and adapters. Measured against the tree, three bodies of code sit outside that sentence:

1. **The Ruby runtime.** It is the reference implementation (ADR 0010) and a second kernel, written
   by hand. ADR 0010 already says one kernel per runtime; the sentence, read literally, allows
   one kernel.
2. **The host core.** Dispatch with replay and snapshots, journal names, IR reading, presentation,
   the UI schema, the wasm runner, plugins. It is domain-agnostic like the kernel, and it does I/O,
   which the kernel may not (ADR 0012: no filesystem, no network, no clock, so the one source runs
   natively and as WASI wasm and is diffed byte for byte against Ruby). It is neither a kernel nor,
   as written today, an adapter.
3. **The generators.** `rust/codegen`, the Ruby projector and `lib/hecks/projections`, the parser
   generator, the language server, the build tooling. `CLAUDE.md` names them as a third kind
   beside the kernel, so the written rule already has three categories, not two.

The sentence is right as a direction and wrong as a count. What it needs is a place for each of the
three that is a rule, not an exception, so a gate can check it the way `hecksagon_boundary_tests.rs`
checks the hexagon today.

## Decision

Every decision says which side it is on.

1. **Rule: a hand-written file is one of three things.** A **kernel** is domain-agnostic and does no
   I/O: it reads data the generated code hands it and answers. An **adapter** does I/O behind a port
   a `.port` file declares, with a `.adapter` file naming its defaults (ADR 0106). A **projector**
   reads canonical IR, or a chapter of the language, and writes an output nobody edits. A file that
   is none of these is the finding. Bluebooks, hecksagons, worlds and behaviors are not code and are
   not counted; generated output is the projector's, not hand-written.

2. **Kernel: one per runtime, and no I/O in any of them.** The Ruby runtime is the Ruby kernel and
   the reference implementation; the Rust kernel is its counterpart. The sentence "only the kernel"
   is read as "only a kernel", never as "pull the host's I/O into the kernel": the kernel's worth is
   that it has none. A kernel that grew a clock or a store would end the three-way diff.

3. **Adapter: the host is the adapter of the dispatch port.** `lib/hecks/ports/dispatch.port` exists
   (ADR 0149). The host core's job, stated as that adapter, is: take a request, give the kernel a
   seed and the steps since it, persist what comes back, deliver what the kernel returned for
   elsewhere. Each piece of the host core is then sorted by the rule:
   - A piece with no I/O belongs in the kernel. `expr_json.rs` is the standing example: it
     re-implements the kernel's evaluator and has already disagreed with it (ADR 0149 point 4).
     Presentation and reference validation are the next candidates.
   - A piece with I/O belongs behind a port. The store is one (ADR 0149). The clock, the wasm
     runner, the cross-domain invoker and the plugin runner each name theirs.
   - What is left is the dispatch adapter itself: the replay-and-snapshot strategy and the
     transports. That is hand-written and declared, which the rule allows.

4. **Projector: every generator names the chapter it reads.** The parser is the proof: its table is
   projected from the language's own Syntax chapter (ADR 0023), the phrase table from the Sentence
   chapter (ADR 0131), the dispatch order from the Vocabulary chapter. The test for a generator is
   "which chapter, or which IR key, does it read", and a generator that answers "none" is the gap.
   `rust/codegen` reads canonical IR, which is a chapter's export, so it passes; a template that
   hard-codes a rule of the language instead of reading it does not.

5. **Gate: the rule is scanned, then compiled.** A scan over hand-written sources classifies each
   file by the rule and fails on one it cannot place, the way the hexagon scan fails on a driver in
   a runtime module. Where the compiler can hold the line it does: a kernel crate with no I/O
   dependency, an adapter crate that depends on the port's types and not the reverse. The scan is
   the first step and runs in the gate's `quick` stage; the crate boundaries follow as each piece
   moves.

6. **Not decided here: retiring the Ruby runtime.** The Rust-only direction is paused by the user
   (2026-10-05). This record makes Ruby a kernel under the rule; it does not make it the only one
   or the last one.

## Consequences

- The sentence becomes checkable. "Hand-written" stops being a feeling about a directory and
  becomes a classification each file passes or fails.
- The host core shrinks in a known direction: I/O-free pieces move into the kernel, I/O pieces go
  behind ports, and what remains is the dispatch adapter. The evaluator merge is the first move,
  and it is feature-sized (the kernel's `Value` has no object variant and answers refusals, not
  strings).
- A generator gets a provenance: the chapter it projects. A language change then lists the
  generators it reaches by reading the chapter's consumers, not by searching for templates.
- Two kernels stay, until the user decides otherwise. The conformance corpus keeps them honest.
- The rule says nothing about size. The kernel is not required to be small, only to be free of
  I/O and of domain.

## Rejected alternatives

- **"Only the kernel", read literally.** Either the host's I/O moves into the kernel, which breaks
  ADR 0012 and the three-way diff, or the host is left as an exception nobody can name, which is the
  state today.
- **Two categories, with generators as a special case.** A special case is where the next
  hand-written thing goes. Naming projectors as a kind, with a test (which chapter), closes it.
- **Retiring Ruby in this record.** A different decision with a different owner; see point 6.
- **A directory convention instead of a scan.** Directories already say where a thing is; the
  three places that break the rule are each in a well-named directory. The scan reads what the
  file does.
