require "spec_helper"
require "json"
require "hecks/fuzzing"
require_relative "../support/postgres_probe"

# A write is all or nothing on every store: when the outbox write inside a dispatch's commit
# fails, the record, its journal entry, its outbox rows and the event log all read as they did
# before the dispatch. The crash is injected in-process by failing the store's outbox write.
RSpec.describe "a write that crashes before it commits, on every store", :aggregate_failures do
  # Store-level parts: what the store's own transaction is answerable for.
  STORE_PARTS = %i[instances journal outbox].freeze

  def pizzas = File.join(InMemoryDomain::ROOT, "examples/pizzas")

  def create_args = JSON.parse(File.read(File.join(InMemoryDomain::ROOT, "spec/corpus/pizzas.json")))["steps"].first["args"]

  # The parts of the runtime a crashed CreatePizza changed, read before and after it.
  def changed_by_crash(store)
    Hecks::Fuzzing::IsolatedBoot.call(pizzas, adapter: store) do |copy|
      runtime = Hecks.boot(copy, environment: nil)
      before = Hecks::Fuzzing::Replay::RefusalTrace.snapshot(runtime)
      crash_outbox(runtime)
      expect { create_pizza(runtime) }.to raise_error(IOError)
      after = Hecks::Fuzzing::Replay::RefusalTrace.snapshot(runtime)
      before.keys.reject { |part| before[part] == after[part] }
    end
  end

  def crash_outbox(runtime)
    aggregate = runtime.registry.bluebook("Pizzas").aggregate("Order")
    allow(runtime.registry.repository("Pizzas", aggregate).adapter).to receive(:outbox_enqueue).and_raise(IOError, "disk gone")
  end

  def create_pizza(runtime)
    Hecks.as_caller(role: "Chef") { runtime.dispatch_flat("Pizzas::Order.CreatePizza", **create_args.transform_keys(&:to_sym)) }
  end

  it "leaves the record, journal and outbox unwritten on SQLite" do
    expect(changed_by_crash(:sqlite) & STORE_PARTS).to be_empty
  end

  it "leaves the record, journal and outbox unwritten on Postgres", :io do
    skip "no reachable Postgres" unless PostgresProbe.available?

    expect(changed_by_crash(:postgres) & STORE_PARTS).to be_empty
  end

  it "leaves the record, journal and outbox unwritten on Memory",
     pending: "Memory#transaction only yields, so a crash after save keeps the record and its journal entry" do
    expect(changed_by_crash(:memory) & STORE_PARTS).to be_empty
  end

  it "leaves the event log without the crashed write's event",
     pending: "the runtime appends to its event log inside the commit and does not take it back on a crash" do
    expect(changed_by_crash(:sqlite)).not_to include(:events)
  end
end
