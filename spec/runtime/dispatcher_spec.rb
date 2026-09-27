require "spec_helper"

# Reaction depth in `Dispatcher#reenter` is per-thread: the dispatcher is shared across
# worker threads, and a Mutex would deadlock because a cascade re-enters on the same thread.
RSpec.describe Hecks::Runtime::Dispatcher do
  def bare_dispatcher
    Hecks::Runtime::Dispatcher.new(Hecks::Runtime::Registry.new)
  end

  describe "#reenter reaction-depth tracking" do
    it "keeps same-thread nested reactions counting depth correctly, up to the ceiling" do
      dispatcher = bare_dispatcher
      levels_entered = 0

      # Each stubbed `dispatch_flat` recurses one level deeper via `reenter`, like a real
      # policy/saga cascade, and checks `reaction_depth_reached?` before recursing.
      dispatcher.define_singleton_method(:dispatch_flat) do |verb, _args = {}|
        levels_entered += 1
        dispatcher.reenter("Nested::deeper") unless dispatcher.reaction_depth_reached?
      end

      dispatcher.reenter("Nested::top")

      # The cascade stops exactly at MAX_REACTION_DEPTH, and depth resets once it unwinds.
      expect(levels_entered).to eq(dispatcher.max_reaction_depth)
      expect(dispatcher.reaction_depth_reached?).to be(false)
    end

    # Two-thread race; the Queue handshakes pin the interleaving, so splitting would break it.
    # rubocop:disable-next RSpec/ExampleLength
    it "does not let one thread's unrelated top-level dispatch corrupt another thread's in-flight reaction depth" do
      dispatcher = bare_dispatcher

      # Thread A nests 4 reactions deep (under the ceiling of 5) and pauses in its innermost
      # frame until Thread B starts an unrelated top-level `reenter`. B must start at depth 0.
      a_reached_bottom = Queue.new
      b_has_entered    = Queue.new
      a_checked        = Queue.new
      a_result         = Queue.new

      a_level = 0
      dispatcher.define_singleton_method(:dispatch_flat) do |verb, _args = {}|
        case verb
        when "A::step"
          a_level += 1
          if a_level < 4
            dispatcher.reenter("A::step")
          else
            a_reached_bottom << true
            b_has_entered.pop
            # A is 4 deep (< 5), so this must be false whatever B does. It is checked before
            # B unwinds, while a shared counter would still hold B's write.
            a_result << dispatcher.reaction_depth_reached?
            a_checked << true
          end
        when "B::top"
          # B is held inside its own `reenter` until A has checked; unwinding earlier
          # could restore a shared counter before A observes it, hiding the race.
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
