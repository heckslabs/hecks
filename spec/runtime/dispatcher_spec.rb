require "spec_helper"

# M20 (docs/audits/2026-08-11-bug-triage.md, docs/audits/2026-08-10-main-bug-audit.md):
# `Dispatcher#reenter` tracked "how deep into a reaction cascade am I" with a
# plain instance ivar (`@reaction_depth`) on a `Dispatcher` that is shared
# across every Puma worker thread. Two concurrent TOP-LEVEL dispatches on
# different threads incremented/decremented the SAME counter, so one
# thread's nested-reaction depth leaked into another thread's unrelated
# dispatch — either masking a real runaway-recursion condition or
# (as demonstrated below) falsely tripping `reaction_depth_reached?` for a
# thread that never actually nested that deep.
#
# `registry.rb`'s own `@saga_mutex` comment already named this exact hazard
# by cross-reference before this spec existed. A `Mutex` is NOT the fix here
# (see that same comment, and `SagaInterpreter#advance_saga`'s: a reaction
# cascade re-enters `reenter` on the SAME thread, and `Mutex` is not
# reentrant) — the depth needs to be per-THREAD, not serialized across
# threads. `Runtime::Caller` (`caller.rb`) already established the idiom
# this file now follows: `Thread.current[...]`, saved/restored around the
# call with a plain local + `ensure`.
RSpec.describe Hecks::Runtime::Dispatcher do
  def bare_dispatcher
    Hecks::Runtime::Dispatcher.new(Hecks::Runtime::Registry.new)
  end

  describe "#reenter reaction-depth tracking" do
    it "keeps same-thread nested reactions counting depth correctly, up to the ceiling" do
      dispatcher = bare_dispatcher
      levels_entered = 0

      # Each `dispatch` stub call recurses one level deeper via `reenter`,
      # exactly the shape a real policy/saga cascade produces (a triggered
      # command's own announced events re-entering `@policies.react` /
      # `@sagas.advance`, which call `door.reenter` again) — and, exactly
      # like `PolicyInterpreter`/`SagaInterpreter` themselves, checks
      # `reaction_depth_reached?` BEFORE recursing again rather than after.
      dispatcher.define_singleton_method(:dispatch) do |verb, **_args|
        levels_entered += 1
        dispatcher.reenter("Nested::deeper") unless dispatcher.reaction_depth_reached?
      end

      dispatcher.reenter("Nested::top")

      # The cascade must stop exactly at MAX_REACTION_DEPTH (same-thread
      # recursion is legitimate and expected to work up to the ceiling),
      # and once the whole cascade has unwound, this thread's depth must be
      # back to a clean slate — not stuck reporting the ceiling forever.
      expect(levels_entered).to eq(dispatcher.max_reaction_depth)
      expect(dispatcher.reaction_depth_reached?).to be(false)
    end

    # A genuine two-thread race, with Queue-based handshakes pinning the
    # exact interleaving needed to prove thread isolation of reaction
    # depth; splitting would break the very synchronization the test
    # depends on to reproduce the race deterministically.
    # rubocop:disable-next RSpec/ExampleLength
    it "does not let one thread's unrelated top-level dispatch corrupt another thread's in-flight reaction depth" do
      dispatcher = bare_dispatcher

      # Thread A nests 4 real reactions deep (MAX_REACTION_DEPTH is 5, so 4
      # is legitimately still under the ceiling) and then, from its
      # INNERMOST frame, pauses — still "inside" its own reaction cascade —
      # until Thread B has independently run its own single, unrelated
      # top-level `reenter` to completion-in-progress. Thread B's read of
      # "what's my starting depth" must be 0 (a fresh top-level dispatch on
      # its own thread), never whatever Thread A's concurrent nesting
      # happens to have left in a shared counter.
      a_reached_bottom = Queue.new
      b_has_entered    = Queue.new
      a_checked        = Queue.new
      a_result         = Queue.new

      a_level = 0
      dispatcher.define_singleton_method(:dispatch) do |verb, **_args|
        case verb
        when "A::step"
          a_level += 1
          if a_level < 4
            dispatcher.reenter("A::step")
          else
            # INNERMOST: A is now 4 reactions deep on its own thread.
            a_reached_bottom << true
            b_has_entered.pop
            # THE ASSERTION THAT MATTERS: A is genuinely 4 deep (< 5), so
            # this must read false regardless of anything Thread B does
            # concurrently on the shared/unshared counter. Checked and
            # signaled BEFORE Thread B is allowed to unwind (below) — under
            # the bug, B's `reenter` ensure hasn't restored anything yet at
            # this exact point, so the shared ivar is still holding B's
            # contaminated write.
            a_result << dispatcher.reaction_depth_reached?
            a_checked << true
          end
        when "B::top"
          # B is a brand-new top-level dispatch on its own thread. Under the
          # bug, `reenter`'s `depth = @reaction_depth.to_i` reads Thread A's
          # in-flight value (4) off the shared ivar and bumps it to 5 —
          # exactly at the ceiling — before Thread A ever gets to check.
          # B is held here, still "inside" its own `reenter` (its `ensure`
          # cannot run until this method returns), until A has checked —
          # otherwise B's own unwind could restore the shared ivar before A
          # ever observes the contaminated value, hiding the race.
          b_has_entered << true
          a_checked.pop
        end
      end

      thread_a = Thread.new { dispatcher.reenter("A::step") }
      thread_b = Thread.new do
        a_reached_bottom.pop
        dispatcher.reenter("B::top")
      end

      thread_a.join
      thread_b.join

      expect(a_result.pop).to be(false)
    end
  end
end
