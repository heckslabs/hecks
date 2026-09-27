require "spec_helper"

# Pins Registry#saga_persistence to one adapter per domain when two threads race the first lookup.
# A split would send one domain's saga writes to two different stores.
RSpec.describe Hecks::Runtime::Registry do
  describe "#saga_persistence" do
    it "resolves a domain's saga persistence adapter at most once and hands every caller the SAME instance, " \
       "even when the first lookup is raced by two threads" do
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
      entered.pop

      # B starts only after A is mid-resolution; without the lock, B would resolve too.
      thread_b = Thread.new { results << registry.saga_persistence("Widgets") }

      # The timeout only bounds the wait for B's second entry; it is not synchronization.
      entered.pop(timeout: 1)

      release << true
      release << true # covers B having raced in and parked on its own release.pop

      thread_a.join
      thread_b.join

      first  = results.pop
      second = results.pop

      expect(resolve_calls).to eq(1)
      expect(first).to be(second)
    end
  end
end
