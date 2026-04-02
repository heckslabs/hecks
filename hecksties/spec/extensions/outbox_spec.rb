require "spec_helper"
require "hecks/extensions/outbox"

RSpec.describe "outbox extension" do
  let(:domain) do
    Hecks.domain "OutboxTest" do
      aggregate "Widget" do
        attribute :name, String
        command "CreateWidget" do
          attribute :name, String
        end
      end
    end
  end

  def fresh_boot
    Hecks.extension_registry.delete(:outbox)
    load File.expand_path("../../../lib/hecks/extensions/outbox.rb", __FILE__)

    app = Hecks.load(domain)
    mod = Object.const_get("OutboxTestDomain")
    Hecks.extension_registry[:outbox]&.call(mod, domain, app, enabled: true)
    app
  end

  it "stores events in the outbox" do
    app = fresh_boot
    app.run("CreateWidget", name: "Sprocket")

    expect(Hecks.outbox.entries.size).to eq(1)
    expect(Hecks.outbox.entries.first[:event].name).to eq("Sprocket")
  end

  it "poller drains outbox and publishes to event bus" do
    app = fresh_boot
    app.run("CreateWidget", name: "Gear")

    expect(Hecks.outbox.pending_count).to eq(0)
    expect(app.events.size).to eq(1)
  end

  it "marks entries as published after drain" do
    app = fresh_boot
    app.run("CreateWidget", name: "Bolt")

    entry = Hecks.outbox.entries.first
    expect(entry[:published]).to eq(true)
  end

  it "reports poller stats" do
    app = fresh_boot
    app.run("CreateWidget", name: "Nut")

    stats = Hecks.outbox_poller.stats
    expect(stats[:published]).to eq(1)
    expect(stats[:pending]).to eq(0)
  end

  it "handles multiple commands" do
    app = fresh_boot
    app.run("CreateWidget", name: "Alpha")
    app.run("CreateWidget", name: "Beta")

    expect(Hecks.outbox.entries.size).to eq(2)
    expect(Hecks.outbox.pending_count).to eq(0)
    expect(app.events.size).to eq(2)
    expect(Hecks.outbox_poller.stats[:published]).to eq(2)
  end
end

RSpec.describe Hecks::Outbox::MemoryOutbox do
  subject(:outbox) { described_class.new }

  let(:fake_event) { Struct.new(:name).new("TestEvent") }

  it "stores events and returns entries" do
    entry = outbox.store(fake_event)
    expect(entry[:id]).not_to be_nil
    expect(entry[:event]).to eq(fake_event)
    expect(entry[:published]).to eq(false)
  end

  it "polls only unpublished entries" do
    outbox.store(fake_event)
    outbox.store(fake_event)
    outbox.mark_published(outbox.entries.first[:id])

    expect(outbox.poll.size).to eq(1)
  end

  it "respects poll limit" do
    5.times { outbox.store(fake_event) }
    expect(outbox.poll(limit: 2).size).to eq(2)
  end

  it "reports pending count" do
    outbox.store(fake_event)
    outbox.store(fake_event)
    expect(outbox.pending_count).to eq(2)

    outbox.mark_published(outbox.entries.first[:id])
    expect(outbox.pending_count).to eq(1)
  end

  it "clears all entries" do
    outbox.store(fake_event)
    outbox.clear
    expect(outbox.entries).to be_empty
  end
end

RSpec.describe Hecks::Outbox::OutboxPoller do
  let(:outbox) { Hecks::Outbox::MemoryOutbox.new }
  let(:event_bus) { Hecks::EventBus.new }
  subject(:poller) { described_class.new(outbox, event_bus) }

  let(:fake_event) { Struct.new(:name).new("TestEvent") }

  it "drains unpublished entries to the event bus" do
    outbox.store(fake_event)
    outbox.store(fake_event)

    count = poller.drain
    expect(count).to eq(2)
    expect(event_bus.events.size).to eq(2)
    expect(outbox.pending_count).to eq(0)
  end

  it "tracks cumulative stats" do
    outbox.store(fake_event)
    poller.drain
    outbox.store(fake_event)
    poller.drain

    expect(poller.stats).to eq(published: 2, pending: 0)
  end

  it "uses custom publisher when provided" do
    delivered = []
    custom_pub = ->(event) { delivered << event }
    custom_poller = described_class.new(outbox, event_bus, publisher: custom_pub)

    outbox.store(fake_event)
    custom_poller.drain

    expect(delivered.size).to eq(1)
    expect(event_bus.events).to be_empty
  end
end
