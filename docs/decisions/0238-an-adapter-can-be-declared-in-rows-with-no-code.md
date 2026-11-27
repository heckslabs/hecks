# An adapter can be declared in rows, with no code behind it

**Status:** Proposed. Date: 2026-11-27. Builds on
[0154](0154-hand-written-code-is-a-kernel-an-adapter-or-a-projector.md) and
[0171](0171-an-adapter-says-whether-it-stays-inside-and-a-behaviors-suite-loads-by-that.md).

## Context

Every adapter today is a declaration and a Ruby class. The `.adapter` file names a port, and a class
under `Hecks::Adapters` answers each ask by a method named after it. Many adapters do not need that
class. A stand-in for a behaviors suite, a recorded fixture or a fixed rate card only maps asked values
to an answer. That is data. Writing it in Ruby puts a hand-written class beside the domain that a reader
has to trust, that the closed vocabulary cannot check, and that a test must mock.

## Decision

1. **An adapter may answer its port from rows.** `replies "Ask", where: {...}, with: {...}` answers an
   ask or a port-answered query. `refuses "Ask", where: {...}, saying: "..."` refuses one. The first row in
   file order whose `where` holds wins. A row with no `where` matches every asking. A `where` compares an
   asked field's scalar, the inside of a `{ value: x }` wrapper or a bare value. `echoing: [:field]` copies
   asked fields into the answer. A query's `with:` may be a list of rows. An asking no row matches is
   refused, naming the adapter, the ask and the values the rows look at.
2. **The rows are data only.** Strings, integers, `true`, `false`, `nil`, hashes and lists: no floats, no
   symbols in an answer, no constants or calls. The Rust parser refuses anything else by name.
3. **Rust is the one reader and the one answerer.** `hecks-parse adapter` prints the rows and
   `hecks-parse reply <file> <adapter> <ask>` answers one asking, read as JSON on stdin. Ruby holds no
   matcher: the builder records that rows exist and fetches them from the parser, and
   `Runtime::DeclaredAdapter` hands each asking to `hecks-parse reply`. A refusal is a `RemoteRefusal`,
   so an ask announces its `refuses` event and a query refuses, as for any adapter.
4. **A declared adapter stays inside.** It runs nothing, so `stays_inside?` holds without saying it, and a
   behaviors suite may boot it.
5. **A suite is its port's contract.** Two stand-ins in `behavior_adapters/` for one port are rivals, not a
   conflict: the runner and the RSpec shim run the suite once per rival and label each result with the
   adapter. Swapping an adapter is a file beside the suite, never a mock.

## Consequences

- A fixture or a stand-in is a declaration that the language judges, not a class.
- The corpus-owned Courier domain (`spec/corpus/declared`) holds one port answered by two declared
  carriers, and its suite runs against each.
- The Ruby DSL still evaluates the `.adapter` block before the parser reads it, as it does for every
  file today. Closing that path belongs to loading through the closed form, not to this record.
- The Rust kernel does not answer ports yet, so a suite with declared stand-ins waits for a kernel
  feature, as other port-using suites do.
