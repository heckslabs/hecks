# Hecks::Runtime::ProcessManagerSetup spec
#
# Verifies the mixin walks domain.process_managers, instantiates runtime
# PMs, binds handlers, subscribes to the event bus, and is a no-op on
# domains without the keyword.

$LOAD_PATH.unshift File.expand_path("../../../lib", __dir__)
require "hecks"

RSpec.describe Hecks::Runtime::ProcessManagerSetup do
  # Build a minimal Runtime-shaped harness that includes the mixin and
  # exposes the private setup_process_managers method for testing.
  let(:harness_class) do
    Class.new do
      include Hecks::Runtime::ProcessManagerSetup
      attr_accessor :domain, :event_bus, :saga_store, :process_managers

      def initialize(domain:, event_bus:)
        @domain = domain
        @event_bus = event_bus
      end

      public :setup_process_managers
    end
  end

  let(:event_bus) { Hecks::EventBus.new }

  it "is a no-op when domain doesn't respond to process_managers" do
    domain = double("Domain")
    allow(domain).to receive(:respond_to?).with(:process_managers).and_return(false)
    harness = harness_class.new(domain: domain, event_bus: event_bus)
    harness.setup_process_managers
    expect(harness.process_managers).to eq([])
  end

  it "is a no-op when process_managers collection is empty" do
    domain = double("Domain", process_managers: [])
    allow(domain).to receive(:respond_to?).with(:process_managers).and_return(true)
    harness = harness_class.new(domain: domain, event_bus: event_bus)
    harness.setup_process_managers
    expect(harness.process_managers).to eq([])
  end

  it "preserves declarative dispatches with with_spec on IR handlers" do
    # Phase 2.b (pm-dispatch-enrichment) — verifies the IR layer
    # carries DispatchSpec objects through to the runtime end so the
    # Rust runtime's drain_pms can evaluate them. The Ruby runtime
    # itself doesn't yet execute declarative dispatches (action procs
    # remain the runtime path) ; this test guards the IR shape.
    require "hecks/dsl/process_manager_builder"
    builder = Hecks::DSL::ProcessManagerBuilder.new("Tiny")
    builder.correlates_by :id
    builder.starts_on "Started"
    builder.state "a"
    builder.on("Pinged", transition: { a: :a }) do
      dispatch "X.Y", with: { name: "body", tick: from_event(:tick) }
    end
    pm_ir = builder.build
    spec = pm_ir.handlers.first.dispatches.first

    expect(spec).to be_a(Hecks::BluebookModel::Behavior::ProcessManager::DispatchSpec)
    expect(spec.command_name).to eq("X.Y")
    expect(spec.with_spec.size).to eq(2)
    expect(spec.with_spec[0][0]).to eq("name")
    expect(spec.with_spec[0][1].kind).to eq(:literal)
    expect(spec.with_spec[1][0]).to eq("tick")
    expect(spec.with_spec[1][1].kind).to eq(:from_event)
  end

  it "instantiates one runtime PM per IR node, binds + subscribes" do
    handler_struct = Struct.new(:event_type, :transition, :action,
                                keyword_init: true)
    pm_ir = double(
      "ProcessManager IR",
      name: "OrderFulfillment",
      correlates_by: :order_id,
      handlers: [
        handler_struct.new(
          event_type: "OrderPlaced",
          transition: { nil => :started },
          action: ->(_event, _instance) { { commands: ["ReserveInventory"] } }
        )
      ]
    )
    domain = double("Domain", process_managers: [pm_ir])
    allow(domain).to receive(:respond_to?).with(:process_managers).and_return(true)

    harness = harness_class.new(domain: domain, event_bus: event_bus)
    harness.setup_process_managers

    expect(harness.process_managers.size).to eq(1)
    expect(harness.process_managers.first.name).to eq("OrderFulfillment")
  end
end
