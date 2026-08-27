require "spec_helper"

# THE MECHANICAL FOLLOW-UP TO M20 (see spec/runtime/dispatcher_spec.rb's own
# header), found by `Hecks/ThreadSharedIvarMutation`
# (lib/rubocop/cop/hecks/thread_shared_ivar_mutation.rb) flagging
# `Registry#saga_persistence`'s old body:
#
#   def saga_persistence(domain)
#     (@saga_persistence ||= {})[domain.to_s] ||= resolve_saga_persistence(domain.to_s)
#   end
#
# `saga_persistence(domain)` is called from LIVE dispatch — every saga
# transition (`SagaInterpreter#checkpoint`, called from `begin_saga`/
# `advance_saga`/`end_saga`) resolves it — so the FIRST call for a given
# domain can come from any dispatching thread, not just the boot thread.
# `resolve_saga_persistence` does real work (a `BindingPolicy.resolve` plus a
# lazy `repository` build) to answer "which adapter instance does this
# domain's sagas persist through", and that answer must be the SAME object
# for every caller: two threads racing the first lookup, each computing and
# caching their own independently-resolved adapter, would silently split one
# domain's saga writes across two different adapter instances — arguably
# worse than M20's `@reaction_depth` bug, which only corrupted a counter,
# not WHICH STORE a saga's state lands in.
#
# `registry/saga_persistence.rb`'s fix: eagerly initialize `@saga_persistence`
# in `Registry#initialize` (removing the race on the CONTAINER), and guard the
# per-domain resolution with a dedicated `@saga_persistence_mutex` (double-
# checked locking) — NOT `@saga_mutex`, which `SagaInterpreter#checkpoint`
# already holds when it calls `saga_persistence`, so reusing it here would
# deadlock the first time any saga advanced (`Mutex` is not reentrant).
#
# THE TEST BELOW forces the exact interleaving the old code got wrong: Thread
# A is made to sit inside `resolve_saga_persistence` for a domain neither
# thread has resolved yet, and Thread B is only started once Thread A is
# confirmed to be in there — i.e., genuinely mid-resolution, before anything
# has been cached. Under the bug, nothing stops Thread B from ALSO calling
# `resolve_saga_persistence` for the same domain concurrently (the outer
# `||=` reads a still-nil/still-unset slot); under the fix, Thread B blocks
# acquiring `@saga_persistence_mutex`, which Thread A holds, and only
# proceeds once Thread A's result is already cached.
#
# The one non-Queue-blocking wait below (`entered.pop(timeout: ...)`) is not
# the synchronization itself — it is a generous, bounded window to observe a
# SECOND entry into `resolve_saga_persistence` for the same domain if the bug
# is present. Under the fix that second entry can never come (Thread B is
# parked on the mutex the whole time), so the wait always elapses in full;
# under the bug, Thread A is blocked with the GVL free the moment Thread B is
# created, so Thread B races in almost immediately — the timeout is a ceiling
# to catch that race reliably, not a sleep this test's correctness depends on.
RSpec.describe Hecks::Runtime::Registry do
  describe "#saga_persistence" do
    it "resolves a domain's saga persistence adapter at most once and hands every caller the SAME instance, even when the first lookup is raced by two threads" do
      registry = described_class.new

      resolve_calls = 0
      entered = Queue.new
      release = Queue.new

      registry.define_singleton_method(:resolve_saga_persistence) do |_domain|
        resolve_calls += 1
        entered << true
        release.pop
        Object.new
      end

      results = Queue.new

      thread_a = Thread.new { results << registry.saga_persistence("Widgets") }
      entered.pop # Thread A is now inside resolve_saga_persistence, blocked on
      # release.pop — under the fix, holding @saga_persistence_mutex
      # for the entire time it sits there.

      thread_b = Thread.new { results << registry.saga_persistence("Widgets") }

      # Bounded, generous window for Thread B to race in behind Thread A's
      # back (see this file's header for why this is a detection ceiling,
      # not the test's synchronization).
      entered.pop(timeout: 1)

      release << true # let Thread A's resolve_saga_persistence return
      release << true # in case Thread B raced in too (the bug) and is
      # blocked on its OWN call to release.pop

      thread_a.join
      thread_b.join

      first  = results.pop
      second = results.pop

      expect(resolve_calls).to eq(1)
      expect(first).to be(second)
    end
  end
end
