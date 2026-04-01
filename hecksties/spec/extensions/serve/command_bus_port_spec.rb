require "spec_helper"
require "hecks/extensions/serve/command_bus_port"

RSpec.describe Hecks::HTTP::CommandBusPort do
  before(:all) do
    @domain = Hecks.domain "PortTest" do
      aggregate "Widget" do
        attribute :name, String

        command "CreateWidget" do
          attribute :name, String
        end
      end
    end
    Hecks.load(@domain)
  end

  let(:event_bus) { Hecks::EventBus.new }
  let(:command_bus) { Hecks::Commands::CommandBus.new(domain: @domain, event_bus: event_bus) }
  subject(:port) { described_class.new(command_bus: command_bus) }

  describe "#dispatch" do
    it "routes through the command bus" do
      event = port.dispatch("CreateWidget", name: "Sprocket")
      expect(event.name).to eq("Sprocket")
    end

    it "triggers command bus middleware" do
      log = []
      command_bus.use(:spy) do |command, next_handler|
        log << command.class.name.split("::").last
        next_handler.call
      end

      port.dispatch("CreateWidget", name: "Gear")
      expect(log).to include("CreateWidget")
    end
  end

  describe "#read" do
    let(:klass) { double("WidgetClass") }

    it "calls a public method on the class" do
      allow(klass).to receive(:all).and_return([])
      result = port.read(klass, "Widget", :all)
      expect(result).to eq([])
      expect(klass).to have_received(:all)
    end

    it "raises DispatchNotAllowed for :eval" do
      expect { port.read(klass, "Widget", :eval) }
        .to raise_error(Hecks::HTTP::CommandBusPort::DispatchNotAllowed)
    end

    it "raises DispatchNotAllowed for :system" do
      expect { port.read(klass, "Widget", :system) }
        .to raise_error(Hecks::HTTP::CommandBusPort::DispatchNotAllowed)
    end
  end

  describe "#use (port middleware)" do
    it "fires before command bus dispatch" do
      order = []

      command_bus.use(:bus_mw) do |_cmd, next_handler|
        order << "bus"
        next_handler.call
      end

      port.use(:port_mw) do |_name, _attrs, next_fn|
        order << "port"
        next_fn.call
      end

      port.dispatch("CreateWidget", name: "Bolt")
      expect(order).to eq(%w[port bus])
    end

    it "can short-circuit without calling next" do
      port.use(:blocker) do |_name, _attrs, _next_fn|
        :blocked
      end

      result = port.dispatch("CreateWidget", name: "Blocked")
      expect(result).to eq(:blocked)
      expect(event_bus.events).to be_empty
    end
  end
end
