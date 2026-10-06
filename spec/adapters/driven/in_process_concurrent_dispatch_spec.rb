require "hecks"
require "tmpdir"
require_relative "../../support/concurrency_gap_domain"

# Heki/Memory counterpart of postgres_concurrent_dispatch_spec.rb: two concurrent $6,000 debits
# against $10,000 must not both succeed. Threads share one Registry, hence one adapter.
#
# The mechanism under test is `Runtime::AggregateLock`'s per-key Mutex, not CAS+retry, so the
# spec proves the two `find` calls cannot overlap rather than that a retry recovers.
RSpec.describe "concurrent dispatch against one process-local aggregate (Heki/Memory)" do
  VISION = "The smallest domain that reproduces a lost-update race for a state-dependent command, in one process.".freeze

  def boot_for(adapter_name, dir: nil)
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      load_ports(adapter_name)
      ConcurrencyGapDomain.declare("ConcurrencyGap", vision: VISION)
      Hecks.hecksagon("ConcurrencyGap") { ConcurrencyGap::Account.persisted_by(adapter_name) }
      # Memory declares no settings, so no `Hecks.world`; Heki needs its own tmpdir per example.
      Hecks.world("ConcurrencyGap") { persisted_by("Heki") { dir(dir) } } if adapter_name == "Heki"
    end

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  def load_ports(adapter_name)
    Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
    Kernel.load(InMemoryDomain::EXTRACTION_PORT)
    # Memory is always loaded: `registry.verify!` needs a usable default adapter.
    Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
    unless adapter_name == "Memory"
      Kernel.load(File.join(InMemoryDomain::ROOT, "lib/hecks/adapters/driven/#{adapter_name.downcase}.adapter"))
    end
    Kernel.load(InMemoryDomain::PRISM_ADAPTER)
  end

  def account_repository(dispatcher)
    aggregate = dispatcher.registry.bluebook("ConcurrencyGap").aggregate("Account")
    dispatcher.registry.repository("ConcurrencyGap", aggregate)
  end

  # Pauses the first thread to reach `find` so a concurrent dispatch could also reach it.
  # Under a correct lock nobody can, so the wait times out; later calls wake the first, never wait.
  def install_race_window(adapter, timeout: 0.3)
    original_find = adapter.method(:find)
    arrived = Queue.new
    gate = Mutex.new
    signaled = false
    adapter.define_singleton_method(:find) do |id|
      result = original_find.call(id)
      first = gate.synchronize { !signaled && (signaled = true) }
      first ? arrived.pop(timeout: timeout) : (arrived << true)
      result
    end
  end

  # Dispatches two $6,000 Debits at once and answers how each ended (:succeeded or :refused).
  def race_two_debits(dispatcher)
    outcomes = Queue.new
    Array.new(2) { debit_in_thread(dispatcher, outcomes) }.each(&:join)
    Array.new(2) { outcomes.pop }
  end

  def debit_in_thread(dispatcher, outcomes)
    Thread.new do
      dispatcher.dispatch_flat("ConcurrencyGap::Account.Debit", number: { value: "a" }, amount: { cents: 6_000 })
      outcomes << :succeeded
    rescue Hecks::Runtime::GivenNotMet
      outcomes << :refused
    end
  end

  shared_examples "serializes two concurrent Debits" do |adapter_name|
    let(:dir) { adapter_name == "Heki" ? Dir.mktmpdir("hecks-heki-concurrency-") : nil }
    let(:dispatcher) { boot_for(adapter_name, dir: dir) }

    before do
      dispatcher.dispatch_flat("ConcurrencyGap::Account.Open", number: { value: "a" }, balance: { cents: 10_000 })
      install_race_window(account_repository(dispatcher).adapter)
    end

    after { FileUtils.remove_entry(dir) if dir }

    # A $10,000 account never honors two $6,000 debits: the second `given` sees the committed
    # balance and refuses via `GivenNotMet`.
    it "admits exactly one of two concurrent Debits that together overdraw the account (#{adapter_name})",
       :aggregate_failures do
      expect(race_two_debits(dispatcher)).to contain_exactly(:succeeded, :refused)
      expect(account_repository(dispatcher).find("a")[:balance].to_h[:cents]).to eq(4_000)
    end
  end

  it_behaves_like "serializes two concurrent Debits", "Heki"
  it_behaves_like "serializes two concurrent Debits", "Memory"
end
