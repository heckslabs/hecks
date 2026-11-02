# An adapter says whether it stays inside, and a behaviors suite loads adapters by that

**Status:** Accepted (owner, 2026-11-02). Date: 2026-11-02. Adds one word to the `Adapter` grammar context, so the Rust
parser's `hecks-parse adapter` reads it too.

## Context

A `.behaviors` suite chooses its project adapters by listing files in `loads`. `Runtime::Loader.load_files`
(`lib/hecks/runtime/loader.rb`) loads the project's adapters only when no `.adapter` is among the listed
files: "An `.adapter` among them stands in for the shared root's adapters, which are then left unloaded,
so a test can answer a port with its own adapter and never construct the domain's real one."
`adapters/driven/folder.rb` does the same. Library adapters (`load_library`) always load; the rule gates
project adapters only.

The rule is safe and costly. It is safe because an adapter that calls a model, the network or the host is
never built in a test unless someone names it. It is costly because a suite that stubs one port must name
every other adapter it wants by path. Miette's `thinking.behaviors` and `sleep_ends.behaviors` list
`adapters/moments.adapter`, `adapters/renderer.adapter` and `adapters/waker.adapter` by hand beside their
stand-ins in `behavior_adapters/`. Every new adapter means editing each suite, and listing a real adapter
beside a stand-in for the same port refuses the first ask with "2 adapters implement the Thinker port
(AnsweringThinker, Thinker) — the runtime will not choose for you" (`runtime/adapter_lookup.rb`), or fails
the boot when the port answers a bound query (`registry/query_verification.rb`).

Behaviors already hold this safety for persistence: `guard_memory_only!` (`behaviors/expectations/boot.rb`)
refuses a suite whose aggregate is bound to anything but Memory. What is missing is a way to know, without
a list, which adapters are as harmless in a test as Memory is.

## Decision

1. **An adapter may declare that it stays inside.** An adapter file says it on a line of its own:

   ```ruby
   Hecks.adapter "Moments" do
     port "Mind"
     stays_inside
   end
   ```

   The word claims the adapter reaches nothing outside the process and the checkout: no network, no
   model, no host side effect. Its author makes the claim once, in the adapter's own file, beside the code
   it describes.
2. **An adapter that says nothing reaches outside.** A new adapter is kept out of every suite until its
   author says otherwise.
3. **A behaviors suite loads project adapters by that, not by a list.** It loads every project adapter
   that stays inside, and every `.adapter` in the `behavior_adapters/` directory beside the suite. A
   stand-in there replaces the project adapter for the port it declares; the convention is the one Miette
   already follows.
4. **The loader learns the word without running the adapter's Ruby.** A project `.adapter` that reaches
   outside is not evaluated in a suite, so its `require_relative` never runs. The loader reads the
   declaration first and evaluates only the adapters that stay inside.
5. **A port whose adapter reaches outside and has no stand-in is left unbound in the suite.** Its ask is
   refused, as it is today when no adapter is bound (`port_operation_interpreter.rb#ask` turns the wiring
   error into the port's `refuses` event). A port that answers a bound query (`answers_query`) fails the
   boot instead (`registry/query_verification.rb`), so a suite that touches one needs a stand-in.

## Consequences

- Miette's suites drop their adapter lists; `loads` names the bluebook, hecksagon and world only. Moments
  and Renderer read Miette's own journal and can declare `stays_inside`. Waker boots a runtime and sets an
  environment variable (`waker.rb`), so whether it stays inside is its owner's call. Thinker, Dreamer,
  Distiller and Closer reach a model or the host and do not declare it.
- The word is gated as every grammar word is: a row in the `Adapter` grammar context, the `AdapterBuilder`
  method, the Rust parser's keyword table and `hecks-parse adapter`'s JSON. Its corpus use is Miette's
  adapters, under ADR 0025 item 4's exemption for a named external consumer, until an `examples/` project
  in this repository declares it.
- `spec/runtime/boot_files_spec.rb` gains two cases: a stand-in that claims a different port from a
  project adapter that stays inside (both load), and a stand-in for the same port (the stand-in replaces
  it).
- `examples/pizzas/pizzas_behaviors.hecksagon` is unaffected: it is a hecksagon for the behaviors world
  (ADR 0131's convention), not an adapter list, and the console, the sentence form and several specs load
  it.
- Fuzzing isolation is unaffected: `fuzzing/isolated_boot.rb` swaps every port through
  `AdapterLookup.standing_in`, which never passes through `load_files`.

## Alternatives considered

- **A stand-in replaces only the ports it claims, and every other project adapter loads.** Rejected
  after review: it inverts the default, so the next adapter anyone adds that calls a model runs in every
  suite that did not stub it. Miette's `sleep_ends.behaviors` would start building the real Thinker and
  Closer.
- **The suite names the ports it keeps real (`keeps_real "Mind", "Voice"`).** Rejected: still a list kept
  apart from what it describes, which ADR 0121 says an allowance should not be.
- **`provides "stays_inside"`, reusing the capability word.** Rejected: `provides` names something an
  adapter can do beyond its port's contract, and staying inside is a limit on what it does. Reading it as
  a capability would let a capability check answer the wrong question.
- **Keep the lists.** Rejected: they are copied by hand, they drift, and their failure mode is the "will
  not choose" error.

## Open questions

- How the loader reads the declaration before evaluating it: through `hecks-parse adapter`, which already
  reads `.adapter` files as text, or by a Ruby reader of the same declaration.
- Whether naming an `.adapter` in `loads` stays allowed, for a suite that wants one outside adapter on
  purpose (an integration suite), or whether that belongs in a world overlay.
- Whether a stand-in may give canned answers inline in the `.behaviors` file instead of a Ruby class. That
  would be a word of its own, with its own corpus case.
- The spelling. `stays_inside` says what it promises; `local` and `offline` were considered and read as
  where the adapter runs, not what it touches.
