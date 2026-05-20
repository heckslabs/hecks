---
ref: i655
status: designed
priority: medium
posted_at: 2026-05-20
posted_by: Miette (Chris: file this one)
category: framework / runtime / executable_bluebook
value: 'Executable bluebooks (flavour A) — a `.bluebook` file with `#!/usr/bin/env storehouse run` at the top and `chmod +x` runs as a script. `./hello.bluebook` parses, validates, wires adapters, dispatches the declared entrypoint, exits 0. Companion `.hecksagon` declares the outbound ports. The substrate (parser shebang-stripping, `storehouse run`, companion-hecksagon discovery) was already shipped under i558 ; this card files the executable-bluebook handshape as its own first-class example with a tracked, mechanically-verified hello-world.'
links:
  - i558.md
  - i650-executable-bluebook-compile.md
---

# i649 - Executable bluebook (shebang flavour, flavour A)

## Chris's seed (verbatim)

> the executable bluebook is bluebook + runtime + storehouse packaged
> together so a `.bluebook` file is executable. type `./hello.bluebook`
> and it runs.

## Two flavours

The dream is one image with two halves :

**(A) Shebang flavour — this card.** A `.bluebook` carries
`#!/usr/bin/env storehouse run` at the top, `chmod +x` makes it
executable, the OS hands it to `storehouse run`. Light, idiomatic,
depends on `storehouse` being on `$PATH`. Like a shell or Ruby
script.

**(B) Compile-to-binary flavour — i650 (sibling design card).** A
new `storehouse compile foo.bluebook -o foo` subcommand produces a
single self-contained binary with the bluebook bytes baked in. Run
`./foo Aggregate.Command k=v` and the embedded bluebook dispatches.
Heavy, fully portable, demos the autophagy vision concretely.

This card ships (A). The substrate ((B) needs) is named in i650.

## What was already in tree

The infrastructure for (A) landed earlier under i558 (the banner
extraction). Parts already present :

- `parser::strip_shebang` (`rust/src/parser.rs:263`) strips a
  leading `#!...\n` so a shebang line is transparent to the parser.
  Same helper is used by the hecksagon, world, and specializer
  parsers ; all five parse paths tolerate executable bluebooks.
- `storehouse run <file.bluebook> [key=val ...]` (`rust/src/run.rs`)
  reads the file, locates the sibling `<stem>.hecksagon`, wires the
  adapter registry, and dispatches the declared `entrypoint` with
  argv-bound attrs. Exit codes 0/1/2/3/4 per `ExitKind`.
- `rust/tests/shebang_test.rs` pins the parser-strips-shebang
  invariant. `rust/tests/run_script_test.rs` pins the run_script
  exit-code contract for missing / unreadable / no-entrypoint /
  unknown-entrypoint / happy paths.
- `cli/banner/banner.bluebook` is the in-tree proof-of-concept :
  an executable bluebook with `entrypoint "PrintBanner"`, a sibling
  `banner.hecksagon` declaring `:stdout`, invoked as
  `storehouse run cli/banner/banner.bluebook`.

So flavour (A) was de-facto shippable already ; what was missing
was a named, documented hello-world example dedicated to the
shape, plus this card stating the contract.

## What this card ships

1. `examples/executable/hello.bluebook` — the canonical hello-world.
   - Carries the shebang `#!/usr/bin/env storehouse run`.
   - Declares `entrypoint "Greet"` and one aggregate (`Hello`) with
     one command (`Greet`), a `Greeting` value object, a `Phase`
     lifecycle, and the `Greeted` emit.
   - Doc-comment header explains usage and the on-PATH prerequisite.
2. `examples/executable/hello.hecksagon` — the companion that wires
   `:memory` (persistence) + `:stdout` (output port).
3. `rust/tests/executable_hello_test.rs` — integration test that
   asserts the example exists, starts with the canonical shebang,
   parses end-to-end, and runs through `storehouse::run::run_script`
   to `ExitKind::Ok`. Pins the example mechanically so future edits
   to the example or the runner cannot drift past it silently.

## How it runs

```sh
# One-time : compile the runtime and put it on PATH.
cd rust && cargo build --release
ln -s "$PWD/target/release/storehouse" /usr/local/bin/storehouse

# Then either explicit :
storehouse run examples/executable/hello.bluebook

# Or shebang :
chmod +x examples/executable/hello.bluebook
./examples/executable/hello.bluebook
```

Either form parses the bluebook (shebang stripped), parses
`hello.hecksagon`, wires the adapter registry (`:memory` + `:stdout`),
and dispatches `Greet`. The generic dispatch path lands an i622
storehouse-log line on stdout for the dispatch and the emitted
`Greeted` event ; exit code is 0.

No specialised runner is needed — `hello.bluebook` falls through
all four capability detectors in `run_script` (stdin-loop, status,
boot, wake, restructure) and lands in the generic dispatch arm.
That's the point : the smallest path through the executable-
bluebook substrate, exercised by an example a new reader can grok
in one screen.

## Contract surface

The executable-bluebook contract is now :

| Element | Where |
|---|---|
| Shebang interpreter | `#!/usr/bin/env storehouse run` — canonical |
| Parser shebang-tolerance | `parser::strip_shebang` |
| Entrypoint declaration | top-level `entrypoint "CommandName"` in the bluebook |
| Argv-bound attrs | `key=val` pairs after the path |
| Entrypoint override | `entrypoint=Aggregate.Command` argv pair wins |
| Companion adapters | `<stem>.hecksagon` next to the bluebook |
| Exit codes | `ExitKind::{Ok=0, ParseFailure=1, GuardFailure=2, AdapterFailure=3, CommandNotFound=4}` |

## Acceptance

- [x] `examples/executable/hello.bluebook` exists with the canonical
  shebang and an `entrypoint "Greet"` declaration.
- [x] `examples/executable/hello.hecksagon` exists and declares
  `:memory` + `:stdout`.
- [x] `rust/tests/executable_hello_test.rs` exercises
  `storehouse::run::run_script` against the example and asserts
  `ExitKind::Ok`.
- [ ] `cargo test --release` green (pre-push gate).
- [ ] `chmod +x examples/executable/hello.bluebook ;
  ./examples/executable/hello.bluebook` exits 0 in a shell where
  `storehouse` is on PATH (manual smoke ; the integration test
  exercises the same code path through `run_script`).
- [ ] Push to `feat/executable-bluebook` (do NOT merge to main).

## Follow-ups (not in this card)

- The PATH prerequisite is real friction. Options to soften :
  install instructions in the example header (taken), a `bin/`
  symlink that scripts pick up, or eventually (B)'s compiled
  binary which removes the PATH dependency entirely.
- The example currently emits an i622 log line, not a
  human-friendly "Hello, world" string. A friendlier surface
  would route the dispatch through a small specialised runner
  similar to `run_status` or `run_boot`. Out of scope tonight ;
  the goal is the shape, not the prettier output.
- Same example shape would let us teach `storehouse run` as the
  universal door for `.bluebook` files (today some users still
  reach for `storehouse parse / catalog / dispatch`). Documenting
  `run` as the first-encounter verb is its own card.
