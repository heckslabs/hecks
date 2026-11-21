require "time"

# A policy interpreter over a registry that hears settled timings, with a dispatcher whose
# re-entry reacts to a second event: the shape of a reaction that starts another.
module NestedReactions
  # @param name [String] the event's name
  # @return [Hecks::Runtime::Event] an event of `Reflex::Echo`
  def event_named(name)
    Hecks::Runtime::Event.new(name: name, aggregate: "Reflex::Echo", id: "#{name}-1", payload: {},
                              occurred_at: Time.now.utc.iso8601)
  end

  # @return [#call] answers each call the next reading, in seconds
  def readings(*seconds) = -> { seconds.shift }

  # @return [Object] a registry holding `Outer` on `Rang` and `Inner` on `Echoed`
  def settling_registry
    bluebook = Struct.new(:name, :policies) { def aggregate(_name) = nil }.new("Reflex", declared_policies)
    Class.new do
      define_method(:reaction_log) { [] }
      define_method(:log_reaction) { |*, **| nil }
      define_method(:bluebooks) { { "Reflex" => bluebook } }
      define_method(:bluebook) { |_domain| bluebook }
    end.new
  end

  # @return [Array<Hecks::Bluebook::Policy>] `Outer` reacts to `Rang`, `Inner` to `Echoed`
  def declared_policies
    [%w[Outer Rang], %w[Inner Echoed]].map do |name, on|
      Hecks::Bluebook::Policy.new(name: name, on_event: on, trigger_command: "Echo.Ring")
    end
  end

  # Reacts to `Rang` on a thread of its own: spans are kept per thread, and a launcher runs the
  # spec inside its own reactions.
  #
  # @param interpreter [Hecks::Runtime::PolicyInterpreter] the interpreter to react with
  # @param heard [Array] where the settle listener noted the cascade's timings
  # @return [Array<Hash>] the cascade's timings, slowest net time first
  def cascade_of(interpreter, heard)
    Thread.new do
      Hecks::Runtime::PolicyInterpreter::Timing.on_settled { |timings| heard << timings }
      interpreter.react(event_named("Rang"), "Reflex")
      interpreter.settle_timings
      heard.first
    end.value
  end

  # @yield what the first re-entry runs; a later one runs nothing
  # @return [Object] a dispatcher whose first `reenter` runs the block
  def reentering(&)
    Class.new do
      define_method(:reaction_depth_reached?) { false }
      define_method(:max_reaction_depth) { 8 }
      define_method(:reenter) do |*, **|
        next if @entered

        @entered = true
        yield
      end
    end.new
  end
end
