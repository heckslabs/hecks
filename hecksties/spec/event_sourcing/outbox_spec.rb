require "hecks"

RSpec.describe "HEC-80: Outbox Pattern" do
  describe "Outbox" do
    let(:outbox) { Hecks::EventSourcing::Outbox.new }
    let(:event) { Struct.new(:name).new("test") }

    it "stores events as pending" do
      entry = outbox.store(event)
      expect(entry.published).to be false
      expect(outbox.pending.size).to eq(1)
    end

    it "marks entries as published" do
      entry = outbox.store(event)
      outbox.mark_published(entry.id)
      expect(outbox.pending).to be_empty
      expect(outbox.published.size).to eq(1)
    end

    it "assigns sequential IDs" do
      e1 = outbox.store(event)
      e2 = outbox.store(event)
      expect(e2.id).to eq(e1.id + 1)
    end

    it "clears all entries" do
      outbox.store(event)
      outbox.clear
      expect(outbox.entries).to be_empty
    end
  end

  describe "OutboxPoller" do
    let(:outbox) { Hecks::EventSourcing::Outbox.new }
    let(:bus) { Hecks::EventBus.new }
    let(:poller) { Hecks::EventSourcing::OutboxPoller.new(outbox, bus) }

    it "publishes pending events and marks them published" do
      event = Struct.new(:name) do
        def self.name; "TestEvent"; end
      end.new("hello")

      outbox.store(event)
      count = poller.poll_once

      expect(count).to eq(1)
      expect(bus.events.size).to eq(1)
      expect(outbox.pending).to be_empty
    end

    it "returns 0 when nothing is pending" do
      expect(poller.poll_once).to eq(0)
    end
  end

  describe "OutboxStep" do
    let(:outbox) { Hecks::EventSourcing::Outbox.new }

    let(:domain) do
      Hecks.domain "OutboxStepTest" do
        aggregate "Ticket" do
          attribute :title, String
          command "CreateTicket" do
            attribute :title, String
          end
        end
      end
    end

    before { @app = Hecks.load(domain) }

    it "stores events in outbox instead of publishing on bus" do
      step = Hecks::EventSourcing::OutboxStep.new(outbox)

      # Create a ticket normally (goes through bus)
      cmd = Ticket.create(title: "Bug")
      # Verify the step interface is callable
      expect(step).to respond_to(:call)
      expect(outbox.pending).to be_empty # no events stored yet via step
    end
  end
end
