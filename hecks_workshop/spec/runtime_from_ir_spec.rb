require "spec_helper"

# Hecks::Runtime — boot from IR without gem building
#
# Verifies that Hecks.load boots a domain from an in-memory IR object
# (no Bluebook file, no disk writes) and that commands fire events.
RSpec.describe "Hecks.load — boot from IR without gem building" do
  before { allow($stdout).to receive(:puts) }

  def build_domain
    Hecks.domain "IrBootTest" do
      aggregate "Widget" do
        attribute :name, String
        command "CreateWidget" do
          attribute :name, String
        end
      end
    end
  end

  describe "Hecks.load" do
    it "returns a Runtime from a domain IR object" do
      domain = build_domain
      runtime = Hecks.load(domain)
      expect(runtime).to be_a(Hecks::Runtime)
    end

    it "loads the domain module constant without writing to disk" do
      domain = build_domain
      Hecks.load(domain)
      expect(Object.const_defined?("IrBootTestDomain")).to be true
    end

    it "accepts an event_bus: option" do
      domain = build_domain
      bus = Hecks::EventBus.new
      runtime = Hecks.load(domain, event_bus: bus)
      expect(runtime).to be_a(Hecks::Runtime)
    end

    it "executes a command and fires an event via the runtime" do
      domain = build_domain
      events = []
      bus = Hecks::EventBus.new
      original = bus.method(:publish)
      bus.define_singleton_method(:publish) { |e| original.call(e); events << e }

      Hecks.load(domain, event_bus: bus)
      mod = Object.const_get("IrBootTestDomain")
      mod::Widget.create(name: "Sprocket")

      expect(events.size).to eq(1)
      expect(events.first.name).to eq("Sprocket")
    end
  end

  describe "Workshop#execute delegation" do
    it "delegates execute to the playground" do
      wb = Hecks::Workshop.new("WsExecTest")
      pizza = wb.aggregate("Pizza")
      pizza.attr :name, String
      pizza.command("CreatePizza") { attribute :name, String }
      wb.play!
      result = wb.execute("CreatePizza", name: "Margherita")
      expect(result.name).to eq("Margherita")
    end

    it "auto-enters play mode when not already in it" do
      wb = Hecks::Workshop.new("AutoPlayTest")
      widget = wb.aggregate("Widget")
      widget.attr :name, String
      widget.command("CreateWidget") { attribute :name, String }
      expect(wb.play?).to be false
      wb.execute("CreateWidget", name: "Bolt")
      expect(wb.play?).to be true
    end
  end
end
