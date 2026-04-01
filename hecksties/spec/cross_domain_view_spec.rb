require "spec_helper"

RSpec.describe Hecks::CrossDomainView do
  let(:bus) { Hecks::EventBus.new }

  def make_event(name, **attrs)
    fields = attrs.empty? ? { _: nil } : attrs
    klass = Struct.new(*fields.keys, keyword_init: true) do
      define_method(:class) { Class.new { define_method(:name) { name } }.new }
    end
    klass.new(**fields)
  end

  it "projects events into state" do
    view = described_class.new("Dashboard") do
      project("CreatedWidget") { |e, s| s.merge(count: (s[:count] || 0) + 1) }
    end
    view.subscribe(bus)

    bus.publish(make_event("CreatedWidget", name: "A"))
    bus.publish(make_event("CreatedWidget", name: "B"))

    expect(view.state[:count]).to eq(2)
  end

  it "projects multiple event types" do
    view = described_class.new("Summary") do
      project("CreatedOrder") { |e, s| s.merge(orders: (s[:orders] || 0) + 1) }
      project("ShippedOrder") { |e, s| s.merge(shipped: (s[:shipped] || 0) + 1) }
    end
    view.subscribe(bus)

    bus.publish(make_event("CreatedOrder", id: "1"))
    bus.publish(make_event("CreatedOrder", id: "2"))
    bus.publish(make_event("ShippedOrder", id: "1"))

    expect(view.state).to eq({ orders: 2, shipped: 1 })
  end

  it "ignores unregistered events" do
    view = described_class.new("Narrow") do
      project("Important") { |e, s| s.merge(seen: true) }
    end
    view.subscribe(bus)

    bus.publish(make_event("Irrelevant", data: "x"))
    expect(view.state).to eq({})

    bus.publish(make_event("Important", data: "y"))
    expect(view.state).to eq({ seen: true })
  end

  it "resets state" do
    view = described_class.new("Resettable") do
      project("Tick") { |e, s| s.merge(n: (s[:n] || 0) + 1) }
    end
    view.subscribe(bus)

    bus.publish(make_event("Tick"))
    expect(view.state[:n]).to eq(1)

    view.reset
    expect(view.state).to eq({})
  end
end
