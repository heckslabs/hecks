# PRD 01 — Fix the `@reaction_depth` race, and prove it with a concurrent-dispatch test

**Status:** Not started. Confirmed live, self-documented, unfixed.

## The problem

`lib/hecksagain/runtime/dispatcher.rb` tracks `@reaction_depth` as a plain
thread-shared instance variable, incremented/checked with no lock, guarding
against runaway reaction recursion (a policy or saga leg triggering another,
without end). It is the *same class* of hazard `@saga_mutex`
(`lib/hecksagain/runtime/registry.rb:55`) already exists to fix — and the
comment that introduced `@saga_mutex` names `@reaction_depth` explicitly:

> "the same shape of hazard this codebase's own prior audit already flagged
> for `@reaction_depth`, a thread-shared dispatcher ivar with no lock"
> (`registry.rb`, comment above `@saga_mutex`'s declaration)

That prior audit fixed `saga_instances`' own race (mutex + a real 10-thread
test, `spec/runtime/saga_durability_spec.rb`) and left `@reaction_depth`
named but untouched. This PRD closes that.

## Why it matters

Two `Dispatcher` calls racing on the same reaction-depth counter can
undercount (a runaway reaction chain runs past its own ceiling, unbounded)
or overcount (a legitimate reaction chain gets refused as
`reaction_depth_reached` when it never actually got that deep) — both are
silent-until-it-happens failure modes, exactly the kind a single-threaded
test suite can never surface on its own.

## Approach

1. Read `Dispatcher`'s own reaction-depth increment/check/decrement sites in
   full before touching anything — confirm the exact read-modify-write
   window that's unguarded (this PRD does not assume the fix shape yet;
   that's the first real step).
2. Guard it the same way `@saga_mutex` guards `saga_instances` — a `Mutex`
   held across the read-check-write, released before any actual dispatch
   work runs (not across the reaction cascade itself, the same non-
   reentrancy reasoning `saga_interpreter.rb`'s own comment gives for why
   `@saga_mutex` is scoped the way it is).
3. Write a general concurrent-dispatch stress test alongside the fix — not
   just proving the fix works, but establishing the general pattern
   `saga_durability_spec.rb` only proved for one specific race. At minimum:
   several threads racing reaction-triggering dispatches against the same
   runtime/registry, asserting no reaction chain either runs past its own
   declared ceiling or gets refused short of it.
4. While in this area, decide whether the SAME general concurrent-dispatch
   test should also cover a second, previously-untested race: two threads
   racing a *creating* command with the same identity (does `AlreadyExists`
   — `command_interpreter.rb`'s own `hydrate` check — actually hold under
   real contention, or only under the single-threaded assumption every
   existing test makes?). If it's cheap to add given the harness this PRD
   already builds, add it; if it needs a materially different setup, split
   it into its own follow-up rather than block this PRD on it.

## Acceptance criteria

- [ ] `@reaction_depth`'s read-modify-write is provably race-free (a
      concurrent test that would have failed before the fix, passes after).
- [ ] The new concurrent-dispatch test lives beside
      `saga_durability_spec.rb`'s own race test, not duplicating its setup
      wholesale.
- [ ] `bundle exec rspec` stays green; no change to single-threaded dispatch
      behavior or timing.

## Non-goals

- A general audit of every other shared-mutable-state hazard in the
  dispatcher/registry — this PRD closes the one hazard already named and
  confirmed, not a broader concurrency review (that's worth scoping
  separately if this PRD's own stress test turns up something else).
- Making `Dispatcher`/`Registry` safe for concurrent use from *outside* a
  single process (that's an adapter/persistence-layer question, not a
  Ruby-ivar-locking one).
