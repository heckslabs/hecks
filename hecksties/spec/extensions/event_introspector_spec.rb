require "spec_helper"
require "hecks/extensions/web_explorer/event_introspector"
require "hecks/extensions/web_explorer/paginator"

# Lightweight fake events that behave like real domain events
module EventIntrospectorTestEvents
  module Pizza; module Events
    class CreatedPizza
      attr_reader :name, :occurred_at
      def initialize(name:, occurred_at:)
        @name = name; @occurred_at = occurred_at
      end
    end
  end; end

  module Order; module Events
    class PlacedOrder
      attr_reader :quantity, :occurred_at
      def initialize(quantity:, occurred_at:)
        @quantity = quantity; @occurred_at = occurred_at
      end
    end
  end; end
end

RSpec.describe Hecks::WebExplorer::EventIntrospector do
  before(:all) do
    @bus = Hecks::EventBus.new
    @bus.publish(EventIntrospectorTestEvents::Pizza::Events::CreatedPizza.new(name: "Margherita", occurred_at: Time.now - 60))
    @bus.publish(EventIntrospectorTestEvents::Pizza::Events::CreatedPizza.new(name: "Pepperoni", occurred_at: Time.now - 30))
    @bus.publish(EventIntrospectorTestEvents::Order::Events::PlacedOrder.new(quantity: 2, occurred_at: Time.now))
  end

  let(:introspector) { described_class.new([@bus]) }

  describe "#all_entries" do
    it "returns events newest first" do
      entries = introspector.all_entries
      expect(entries.size).to eq(3)
      expect(entries.first[:occurred_at]).to be >= entries.last[:occurred_at]
    end

    it "converts events to hashes with required keys" do
      entry = introspector.all_entries.first
      %i[type aggregate occurred_at payload].each { |k| expect(entry).to have_key(k) }
    end

    it "filters by event type" do
      entries = introspector.all_entries(type_filter: "CreatedPizza")
      expect(entries.size).to eq(2)
      expect(entries).to all(satisfy { |e| e[:type] == "CreatedPizza" })
    end

    it "filters by aggregate" do
      entries = introspector.all_entries(aggregate_filter: "Order")
      expect(entries.size).to eq(1)
      expect(entries.first[:type]).to eq("PlacedOrder")
    end

    it "returns empty when filter matches nothing" do
      expect(introspector.all_entries(type_filter: "NoSuchEvent")).to be_empty
    end

    it "ignores blank filters" do
      all_size = introspector.all_entries.size
      blank_size = introspector.all_entries(type_filter: "", aggregate_filter: "").size
      expect(blank_size).to eq(all_size)
    end

    it "extracts payload from instance variables" do
      pizza_entries = introspector.all_entries(type_filter: "CreatedPizza")
      expect(pizza_entries.first[:payload]).to have_key("name")
    end
  end

  describe "#event_types" do
    it "returns distinct sorted event type names" do
      expect(introspector.event_types).to eq(["CreatedPizza", "PlacedOrder"])
    end
  end

  describe "#aggregate_types" do
    it "returns distinct sorted aggregate names" do
      expect(introspector.aggregate_types).to eq(["Order", "Pizza"])
    end
  end

  describe "multiple event buses" do
    it "merges events from multiple buses" do
      bus2 = Hecks::EventBus.new
      bus2.publish(EventIntrospectorTestEvents::Pizza::Events::CreatedPizza.new(name: "X", occurred_at: Time.now))
      ei = described_class.new([@bus, bus2])
      expect(ei.all_entries.size).to eq(4)
    end
  end
end

RSpec.describe Hecks::WebExplorer::Paginator do
  let(:items) { (1..53).to_a }

  it "returns the first page by default" do
    pager = described_class.new(items)
    expect(pager.current).to eq(1)
    expect(pager.items).to eq((1..25).to_a)
    expect(pager.total_pages).to eq(3)
    expect(pager.total_count).to eq(53)
  end

  it "returns the second page" do
    pager = described_class.new(items, page: 2)
    expect(pager.items).to eq((26..50).to_a)
    expect(pager.previous_page).to eq(1)
    expect(pager.next_page).to eq(3)
  end

  it "returns the last page with remainder" do
    pager = described_class.new(items, page: 3)
    expect(pager.items).to eq([51, 52, 53])
    expect(pager.next_page).to be_nil
    expect(pager.previous_page).to eq(2)
  end

  it "handles empty collections" do
    pager = described_class.new([])
    expect(pager.items).to eq([])
    expect(pager.total_pages).to eq(1)
    expect(pager.current).to eq(1)
  end

  it "clamps invalid page numbers to 1" do
    pager = described_class.new(items, page: -1)
    expect(pager.current).to eq(1)
  end

  it "supports custom per_page" do
    pager = described_class.new(items, per_page: 10)
    expect(pager.items.size).to eq(10)
    expect(pager.total_pages).to eq(6)
  end
end
