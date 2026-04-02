require "hecks"

RSpec.describe "HEC-67: Process Managers" do
  let(:store) { Hecks::SagaStore.new }
  let(:pm) { Hecks::EventSourcing::ProcessManager.new(name: "OrderFulfillment", store: store) }

  let(:order_placed) do
    Struct.new(:order_id, :amount, keyword_init: true) do
      def self.name; "OrderPlaced"; end
    end.new(order_id: "ord-1", amount: 100)
  end

  let(:inventory_reserved) do
    Struct.new(:order_id, keyword_init: true) do
      def self.name; "InventoryReserved"; end
    end.new(order_id: "ord-1")
  end

  let(:payment_received) do
    Struct.new(:order_id, keyword_init: true) do
      def self.name; "PaymentReceived"; end
    end.new(order_id: "ord-1")
  end

  before do
    pm.on("OrderPlaced", correlate: :order_id, transition: { nil => :started }) do |event, instance|
      { commands: ["ReserveInventory"] }
    end
    pm.on("InventoryReserved", correlate: :order_id, transition: { started: :reserved })
    pm.on("PaymentReceived", correlate: :order_id, transition: { reserved: :completed })
  end

  it "creates a new instance on first event" do
    result = pm.handle(order_placed)
    expect(result[:state]).to eq(:started)
    expect(result[:correlation_id]).to eq("ord-1")
    expect(result[:pending_commands]).to eq(["ReserveInventory"])
  end

  it "transitions through states" do
    pm.handle(order_placed)
    pm.handle(inventory_reserved)
    result = pm.handle(payment_received)

    expect(result[:state]).to eq(:completed)
    expect(result[:handled_events]).to eq(["OrderPlaced", "InventoryReserved", "PaymentReceived"])
  end

  it "ignores events that don't match current state" do
    pm.handle(order_placed)
    # Skip InventoryReserved, go straight to PaymentReceived
    result = pm.handle(payment_received)
    # Should not transition because state is :started, not :reserved
    expect(result[:state]).to eq(:started)
  end

  it "returns nil for unknown event types" do
    unknown = Struct.new(:order_id) do
      def self.name; "Unknown"; end
    end.new("ord-1")
    expect(pm.handle(unknown)).to be_nil
  end

  it "subscribes to an event bus" do
    bus = Hecks::EventBus.new
    pm.subscribe_to(bus)
    bus.publish(order_placed)

    instance = store.find("ord-1")
    expect(instance[:state]).to eq(:started)
  end
end
