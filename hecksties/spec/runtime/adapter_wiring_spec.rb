require "spec_helper"
require "hecks/chapters/spec"
require "hecks/adapters/test_helper_adapter"
require "hecks/adapters/event_bus_adapter"

RSpec.describe Hecks::Runtime::AdapterWiring do
  include HecksTemplating::NamingHelpers

  let(:domain) { Hecks::Chapters::Spec.definition }
  let(:app) do
    mod_name = domain_module_name(domain.name)
    Hecks::InMemoryLoader.load(domain, mod_name) unless Object.const_defined?(mod_name)
    Hecks::Runtime.new(domain)
  end

  describe "#adapt" do
    it "registers an adapter for an aggregate" do
      app.adapt("TestHelper", Hecks::Adapters::TestHelperAdapter)
      expect(app.command_bus.middleware.any? { |m| m[:name] == :TestHelper_adapter }).to be true
    end
  end

  describe "TestHelperAdapter" do
    before { app.adapt("TestHelper", Hecks::Adapters::TestHelperAdapter) }

    it "clears event bus on Reset" do
      app.run("Subscribe", event_name: "Test")
      app.run("Publish", event: "hello")
      expect(app.event_bus.events.size).to be >= 2

      app.run("Reset")
      expect(app.event_bus.events.size).to eq(1)
      expect(app.event_bus.events.last.class.name).to include("Reset")
    end
  end

  describe "EventBusAdapter" do
    before { app.adapt("EventBus", Hecks::Adapters::EventBusAdapter) }

    it "clears event bus on Clear command" do
      app.run("Subscribe", event_name: "Foo")
      expect(app.event_bus.events.size).to be >= 1

      app.run("Clear")
      expect(app.event_bus.events.size).to eq(1)
      expect(app.event_bus.events.last.class.name).to include("Cleared")
    end
  end
end
