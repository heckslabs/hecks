require "spec_helper"

# Two threads racing the first `saga_persistence` lookup of a registry: the first parks inside
# the resolution until released, the second starts only once the first is mid-resolution.
class SagaPersistenceRace
  attr_reader :resolve_calls

  # @param registry [Hecks::Runtime::Registry] the registry whose resolution is replaced
  def initialize(registry)
    @resolve_calls = 0
    @entered = Queue.new
    @release = Queue.new
    @results = Queue.new
    race = self
    registry.define_singleton_method(:resolve_saga_persistence) { |_domain| race.park }
  end

  # Stands in for the registry's resolution: counts the call and parks until released.
  #
  # @return [Object] a fresh adapter stand-in
  def park
    @resolve_calls += 1
    @entered << true
    @release.pop
    Object.new
  end

  # Races two lookups and answers what each caller was handed.
  #
  # @param registry [Hecks::Runtime::Registry] the registry both threads ask
  # @return [Array] the two answers
  def run(registry)
    thread_a = lookup(registry)
    @entered.pop
    # B starts only after A is mid-resolution; without the lock, B would resolve too.
    thread_b = lookup(registry)
    # The timeout only bounds the wait for B's second entry; it is not synchronization.
    @entered.pop(timeout: 1)
    2.times { @release << true } # the second covers B having raced in and parked on its own release.pop
    [thread_a, thread_b].each(&:join)
    [@results.pop, @results.pop]
  end

  private

  def lookup(registry) = Thread.new { @results << registry.saga_persistence("Widgets") }
end

# Pins Registry#saga_persistence to one adapter per domain when two threads race the first lookup.
# A split would send one domain's saga writes to two different stores.
RSpec.describe Hecks::Runtime::Registry do
  describe "#saga_persistence" do
    it "resolves a domain's saga persistence adapter at most once and hands every caller the SAME instance, " \
       "even when the first lookup is raced by two threads", :aggregate_failures do
      registry = described_class.new
      race = SagaPersistenceRace.new(registry)

      first, second = race.run(registry)

      expect(race.resolve_calls).to eq(1)
      expect(first).to be(second)
    end
  end
end
