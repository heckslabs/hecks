# Given Predicate Primitives

Bluebook `given { ... }` clauses ship two stochastic / periodic gate
primitives that lift legacy shell-side cadence math (`if [ $((RANDOM
% N)) -eq 0 ]`, `if (tick % N).zero?`) into declarative IR.

## `rand_below(N)` — stochastic 1-in-N gate

`rand_below(N)` returns a uniform random integer in `[0, N)`. Combined
with `== 0` it expresses a 1/N probability gate per dispatch.

```ruby
command "AttemptMint" do
  role "Daemon"
  given { rand_below(300) == 0 }
  emits "MintAttempted"
end
```

At a 1Hz tick driver, `rand_below(300) == 0` fires roughly every 5
minutes. The dispatch is cheap when the gate fails — no mutations, no
events, no downstream policies.

`HECKS_RAND_SEED` env var pins the RNG for tests :

- `HECKS_RAND_SEED=0` → predicate fires every call (returns 0).
- `HECKS_RAND_SEED=k` → returns `k % N`, deterministic for fixture replay.

## `<expr>.modulo(N)` — periodic every-Nth gate

`<expr>.modulo(N)` resolves the receiver as an integer (attribute,
state field, or literal) and returns `receiver % N`. Combined with
`== 0` it fires every Nth call.

```ruby
command "Consolidate" do
  role "System"
  attribute :tick, Integer
  given { tick.modulo(60) == 0 }
end
```

The receiver expression goes through the same lookup chain as any
expression : command attributes shadow state fields, both fall through
to literal numbers. Use it for periodic cadence (Memory.Consolidate
every 60 ticks, MarkConceived every DWELL ticks).

```ruby
# Aggregate with a self-counter — every 10th Tick triggers a sweep.
aggregate "Counter" do
  identified_by :name
  attribute :name, String
  attribute :cycle, Integer, default: "0"

  command "Tick" do
    role "Daemon"
    attribute :cycle, Integer
    then_set :cycle, to: :cycle
  end

  command "Sweep" do
    role "Daemon"
    given { cycle.modulo(10) == 0 }
  end
end
```

## When to use which

- **`rand_below(N)`** — decoupled-from-tick stochastic spacing. Two
  callers gated by `rand_below(N) == 0` fire on independent schedules.
  Best for content production where exact cadence doesn't matter
  (musing minting, daydream wandering).
- **`<expr>.modulo(N)`** — synchronized periodic cadence. All callers
  reading the same tick value fire at the same N-cycle boundary.
  Best for batching sweeps (Memory.Consolidate, statusline cursor
  advance, log rotation).

## Edge cases

Both primitives short-circuit `N <= 0` to `0` instead of panicking —
the predicate fires every call. This is the safer-than-panicking
behavior for daemons : a typo (`rand_below(0)` or `tick.modulo(0)`)
degrades gracefully to "fire every call" rather than crashing the
runtime mid-tick.

## Runtime parity

Both primitives evaluate identically in the Rust runtime
(`rust/src/runtime/interpreter.rs`) and the Ruby parity mirror
(`ruby/hecks/behaviors/interpreter.rb`). Tests in
`rust/tests/runtime_test.rs` exercise both firing and blocking paths.
