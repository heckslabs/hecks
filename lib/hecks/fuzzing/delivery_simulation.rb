# frozen_string_literal: true

require_relative "shrinker"
require_relative "../runtime/adapter_lookup"
require_relative "delivery_simulation/world"
require_relative "delivery_simulation/stand_ins"
require_relative "delivery_simulation/scheduler"
require_relative "delivery_simulation/agent"
require_relative "delivery_simulation/generator"
require_relative "delivery_simulation/invariants"
require_relative "delivery_simulation/shrinking"

module Hecks
  module Fuzzing
    # Replays many agents landing and boarding at once against a booted runtime, with git and CI
    # simulated in memory, and shrinks a schedule that breaks an invariant to the fewest steps
    # that still break it.
    #
    # The `Landing` and `SendTrain` bluebooks run as they are; only what their ports reach is
    # stood in. A replay is a function of its schedule alone, so a finding replays the same way
    # every time. One simulation replays at a time in a process, because the stand-in for the
    # ports is one for the whole process.
    class DeliverySimulation
      # What one replay found.
      #
      # @!attribute [r] divergences
      #   @return [Array<Hash>] `{ field:, detail: }` for each invariant that did not hold
      # @!attribute [r] schedule
      #   @return [Array<Hash>] the steps replayed
      # @!attribute [r] agents
      #   @return [Array<String>] the agents that took part
      # @!attribute [r] outcomes
      #   @return [Hash{String => Array}] by agent, how its landing and its boarding ended
      Result = Struct.new(:divergences, :schedule, :agents, :outcomes, keyword_init: true)

      @replays = 0

      # @return [String] a tag no other replay in this process has
      def self.next_tag = "s#{@replays += 1}"

      # @param runtime [Runtime::Dispatcher] a runtime booted in Memory that holds the `Landing`
      #   and `SendTrain` bluebooks
      # @param stand_ins [Hash{String => #call}] by port name, what builds another stand-in from
      #   the replay's world
      def initialize(runtime, stand_ins: {})
        @runtime = runtime
        @overrides = stand_ins
      end

      # Replays a schedule and checks the invariants. A replay that raises is itself a finding.
      #
      # @param schedule [Array<Hash>] `advance` and `fault` steps, as `Generator` draws them
      # @return [Result] what was found
      def run(schedule)
        world = World.new(self.class.next_tag, pause: Scheduler::PAUSE)
        scheduler = Scheduler.new(world) { |name| Agent.new(@runtime, world, name).run }
        found = play(world, scheduler, schedule)
        Result.new(divergences: found, schedule: schedule, agents: scheduler.agents, outcomes: outcomes(world, scheduler))
      end

      # Shrinks a schedule that breaks an invariant to a small one that breaks the same one.
      #
      # @param schedule [Array<Hash>] a schedule whose replay finds a divergence
      # @param budget [Integer, nil] the most candidates to replay; unbounded when nil
      # @return [Result] the replay of the shrunk schedule
      # @raise [ArgumentError] when the schedule breaks nothing
      def shrink(schedule, budget: nil)
        original = Shrinker.signature(run(schedule).divergences)
        raise ArgumentError, "the schedule breaks no invariant, so there is nothing to shrink" if original.empty?

        run(Shrinking.call(schedule, budget: budget) do |candidate|
          Shrinker.reproduces?(original, run(candidate).divergences)
        end)
      end

      private

      def play(world, scheduler, schedule)
        Runtime::AdapterLookup.standing_in(StandIns.new(world, @overrides)) { scheduler.play(schedule) }
        Invariants.check(facts(world, scheduler))
      rescue StandardError => e
        [{ field: "crash", detail: "#{e.class}: #{e.message}" }]
      end

      def facts(world, scheduler)
        Invariants::Facts.new(@runtime, world, scheduler.agents.map { |name| "#{world.tag}-#{name}" })
      end

      def outcomes(world, scheduler)
        read = facts(world, scheduler)
        scheduler.agents.to_h do |name|
          run = "#{world.tag}-#{name}"
          [name, [read.read(read.landing(run), :status), read.read(read.boarding(run), :status)]]
        end
      end
    end
  end
end
