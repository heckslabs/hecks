require "spec_helper"

# The queue handshakes of a two-thread reaction-depth race. Thread A nests four reactions deep and
# pauses in its innermost frame until thread B starts an unrelated top-level `reenter`.
class DispatcherRaceScript
  attr_reader :a_result

  def initialize
    @a_reached_bottom = Queue.new
    @b_has_entered    = Queue.new
    @a_checked        = Queue.new
    @a_result         = Queue.new
    @a_level          = 0
  end

  # Answers one stubbed `dispatch_flat`: A recurses until it is four deep, B holds still.
  #
  # @param dispatcher [Hecks::Runtime::Dispatcher] the dispatcher whose dispatch is stubbed
  # @param verb [String] the verb being dispatched, "A::step" or "B::top"
  # @return [void]
  def step(dispatcher, verb)
    case verb
    when "A::step" then a_step(dispatcher)
    when "B::top"  then b_top
    end
  end

  # Waits for A to reach its innermost frame, so B only starts once A is paused there.
  #
  # @return [void]
  def wait_for_a
    @a_reached_bottom.pop
  end

  private

  def a_step(dispatcher)
    @a_level += 1
    return dispatcher.reenter("A::step") if @a_level < 4

    @a_reached_bottom << true
    @b_has_entered.pop
    # A is 4 deep (< 5), so this must be false whatever B does. It is checked before
    # B unwinds, while a shared counter would still hold B's write.
    @a_result << dispatcher.reaction_depth_reached?
    @a_checked << true
  end

  # B is held inside its own `reenter` until A has checked; unwinding earlier
  # could restore a shared counter before A observes it, hiding the race.
  def b_top
    @b_has_entered << true
    @a_checked.pop
  end
end

# Reaction depth in `Dispatcher#reenter` is per-thread: the dispatcher is shared across
# worker threads, and a Mutex would deadlock because a cascade re-enters on the same thread.
RSpec.describe Hecks::Runtime::Dispatcher do
  def bare_dispatcher
    Hecks::Runtime::Dispatcher.new(Hecks::Runtime::Registry.new)
  end

  # Each stubbed `dispatch_flat` recurses one level deeper via `reenter`, like a real
  # policy/saga cascade, and checks `reaction_depth_reached?` before recursing.
  def cascading_dispatcher(levels_entered)
    dispatcher = bare_dispatcher
    dispatcher.define_singleton_method(:dispatch_flat) do |_verb, _args = {}|
      levels_entered << true
      dispatcher.reenter("Nested::deeper") unless dispatcher.reaction_depth_reached?
    end
    dispatcher
  end

  def run_race(dispatcher, script)
    thread_a = Thread.new { dispatcher.reenter("A::step") }
    thread_b = Thread.new do
      script.wait_for_a
      dispatcher.reenter("B::top")
    end
    [thread_a, thread_b].each(&:join)
  end

  describe "#reenter reaction-depth tracking" do
    it "keeps same-thread nested reactions counting depth correctly, up to the ceiling", :aggregate_failures do
      levels_entered = []
      dispatcher = cascading_dispatcher(levels_entered)

      dispatcher.reenter("Nested::top")

      # The cascade stops exactly at MAX_REACTION_DEPTH, and depth resets once it unwinds.
      expect(levels_entered.size).to eq(dispatcher.max_reaction_depth)
      expect(dispatcher.reaction_depth_reached?).to be(false)
    end

    # Two-thread race; the Queue handshakes pin the interleaving, so splitting would break it.
    it "does not let one thread's unrelated top-level dispatch corrupt another thread's in-flight reaction depth" do
      dispatcher = bare_dispatcher
      script = DispatcherRaceScript.new
      dispatcher.define_singleton_method(:dispatch_flat) { |verb, _args = {}| script.step(dispatcher, verb) }

      run_race(dispatcher, script)

      expect(script.a_result.pop).to be(false)
    end
  end
end
