require "hecks"
require "json"
require "tmpdir"
require "hecks/bench/workload"
require "hecks/rust_build/kernel_engine"
require_relative "support/rust_conformance_helpers"

# `Hecks.boot(path, engine: :kernel)` returns a KernelDispatcher over a per-domain kernel binary.
# The twin runs the pizzas bench cycle through both engines and compares the events as canonical
# JSON: name, aggregate, id and attributes, with `occurred_at` fixed by one bound clock.
#
# It proves the pizzas cycle only, on a binary built with `--features pizzas`; it says nothing about
# another domain, a refusal's wording, queries, reactions or a store other than Memory.
RSpec.describe Hecks::RustBuild::KernelEngine, :io do
  include RustConformanceHelpers

  let(:pizzas_dir) { File.expand_path("../examples/pizzas", __dir__) }
  let(:stamp) { "2026-01-01T00:00:00Z" }
  let(:workload) { Hecks::Bench::Workload.pizzas }

  around do |example|
    Dir.mktmpdir("kernel-twin") do |dir|
      previous = ENV.fetch("HECKS_EVENT_TAP", nil)
      ENV["HECKS_EVENT_TAP"] = File.join(dir, "events.jsonl")
      example.run
    ensure
      ENV["HECKS_EVENT_TAP"] = previous
    end
  end

  before { allow(Hecks::Runtime::Event).to receive(:stamp).and_return(stamp) }

  def canonical(events)
    events.map do |event|
      JSON.parse(JSON.generate("name" => event.name.to_s, "aggregate" => event.aggregate.to_s,
                               "id" => event.id.to_s, "attributes" => event.payload,
                               "occurred_at" => event.occurred_at.to_s))
    end
  end

  def run_cycle(dispatcher)
    workload.cycle(0).each { |step| dispatcher.dispatch_flat(step.verb, step.ruby_args) }
    dispatcher.events
  end

  def run_engine(engine)
    dispatcher = Hecks.boot(pizzas_dir, install_driving: false, engine: engine)
    canonical(run_cycle(dispatcher))
  ensure
    dispatcher.close if engine == :kernel && dispatcher
  end

  describe "the pizzas cycle" do
    it "announces the same events through both engines", :aggregate_failures do
      ruby = run_engine(:ruby)
      kernel = run_engine(:kernel)

      expect(kernel).not_to be_empty
      expect(kernel).to eq(ruby)
    end
  end

  describe "the engine choice" do
    it "returns a KernelDispatcher for :kernel" do
      dispatcher = Hecks.boot(pizzas_dir, install_driving: false, engine: :kernel)

      expect(dispatcher).to be_a(Hecks::Runtime::KernelDispatcher)
    ensure
      dispatcher&.close
    end

    it "refuses an unknown engine by name" do
      expect { Hecks.boot(pizzas_dir, engine: :wasm) }.to raise_error(ArgumentError, /unknown engine :wasm/)
    end

    it "refuses a domain the Rust workspace has no feature for, never falling back", :aggregate_failures do
      allow(Hecks::RustBuild::NativeBuild).to receive(:build_rust_for).and_return(nil)

      expect { Hecks.boot(pizzas_dir, engine: :kernel) }
        .to raise_error(described_class::BinaryUnavailable, /declares no feature "pizzas"/)
    end
  end

  describe "a refusal" do
    let(:dispatcher) { Hecks.boot(pizzas_dir, install_driving: false, engine: :kernel) }

    after { dispatcher.close }

    it "is raised with the kernel's own text" do
      expect { dispatcher.dispatch_flat("Pizzas::Order.NoSuchCommand", {}) }
        .to raise_error(Hecks::Runtime::KernelDispatcher::Refused, /unknown command/)
    end
  end

  describe "a dispatch inside a dispatch" do
    let(:client) { instance_double(Hecks::RustBuild::KernelClient) }
    let(:dispatcher) { Hecks::Runtime::KernelDispatcher.new(client) }

    it "is refused by name" do
      allow(client).to receive(:dispatch) { dispatcher.dispatch_flat("Pizzas::Order.CreatePizza", {}) }

      expect { dispatcher.dispatch_flat("Pizzas::Order.CreatePizza", {}) }
        .to raise_error(Hecks::Runtime::KernelDispatcher::NestedDispatch, /inside an open dispatch/)
    end
  end

  describe "a domain that does not persist in Memory" do
    it "is refused by name" do
      registry = instance_double(Hecks::Runtime::Registry)
      allow(described_class).to receive(:bound_elsewhere).with(registry).and_return(["Banking::Account (Sqlite)"])

      expect { described_class.require_memory!(registry) }
        .to raise_error(described_class::NotMemory, /Memory only; Banking::Account \(Sqlite\)/)
    end
  end
end
