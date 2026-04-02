require "spec_helper"
require "hecks/extensions/web_explorer/event_introspector"

RSpec.describe Hecks::WebExplorer::EventIntrospector do
  FakeEvent = Struct.new(:name, :occurred_at, keyword_init: true) unless defined?(FakeEvent)

  def make_event(type_name:, aggregate:, occurred_at: Time.now)
    # Build a class whose name matches: DomainModule::Aggregate::Events::EventType
    klass = Class.new(Struct.new(:occurred_at, keyword_init: true))
    mod = Module.new
    events_mod = Module.new
    stub_const("FakeTestDomain::#{aggregate}::Events::#{type_name}", klass)
    klass.new(occurred_at: occurred_at)
  end

  let(:t1) { Time.now - 10 }
  let(:t2) { Time.now - 5 }
  let(:t3) { Time.now }

  let(:pizza_event)  { make_event(type_name: "CreatedPizza",  aggregate: "Pizza",  occurred_at: t1) }
  let(:order_event1) { make_event(type_name: "PlacedOrder",   aggregate: "Order",  occurred_at: t2) }
  let(:order_event2) { make_event(type_name: "CancelledOrder", aggregate: "Order", occurred_at: t3) }

  let(:bus) do
    b = Hecks::EventBus.new
    b.publish(pizza_event)
    b.publish(order_event1)
    b.publish(order_event2)
    b
  end

  subject(:intro) { described_class.new(bus) }

  describe "#all_entries" do
    it "returns all events when no filter given" do
      expect(intro.all_entries.size).to eq(3)
    end

    it "returns newest first" do
      entries = intro.all_entries
      expect(entries.first[:type]).to eq("CancelledOrder")
      expect(entries.last[:type]).to eq("CreatedPizza")
    end

    it "filters by event type" do
      entries = intro.all_entries(type_filter: "PlacedOrder")
      expect(entries.size).to eq(1)
      expect(entries.first[:type]).to eq("PlacedOrder")
    end

    it "filters by aggregate" do
      entries = intro.all_entries(aggregate_filter: "Order")
      expect(entries.size).to eq(2)
      entries.each { |e| expect(e[:aggregate]).to eq("Order") }
    end

    it "returns empty array when bus has no events" do
      empty_bus = Hecks::EventBus.new
      expect(described_class.new(empty_bus).all_entries).to eq([])
    end

    it "includes occurred_at in each entry" do
      entries = intro.all_entries
      entries.each { |e| expect(e[:occurred_at]).to be_a(Time) }
    end

    it "ignores blank type_filter" do
      entries = intro.all_entries(type_filter: "")
      expect(entries.size).to eq(3)
    end
  end

  describe "#event_types" do
    it "returns unique event type names" do
      types = intro.event_types
      expect(types).to include("CreatedPizza", "PlacedOrder", "CancelledOrder")
      expect(types.uniq).to eq(types)
    end
  end

  describe "#aggregate_types" do
    it "returns unique aggregate names" do
      aggs = intro.aggregate_types
      expect(aggs).to include("Pizza", "Order")
      expect(aggs.uniq).to eq(aggs)
    end
  end
end
