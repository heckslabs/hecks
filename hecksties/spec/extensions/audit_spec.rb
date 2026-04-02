require "spec_helper"
require "hecks/extensions/audit"

RSpec.describe Hecks::Audit do
  let(:domain) do
    Hecks.domain "Pizzas" do
      aggregate "Pizza" do
        attribute :name, String

        command "CreatePizza" do
          attribute :name, String
        end
      end
    end
  end

  describe "event capture via event bus" do
    it "records event name and timestamp" do
      app = Hecks.load(domain)
      audit = described_class.new(app.event_bus)

      PizzasDomain::Pizza.create(name: "Margherita")

      expect(audit.log.size).to eq(1)
      entry = audit.log.first
      expect(entry[:event_name]).to eq("CreatedPizza")
      expect(entry[:timestamp]).to be_a(Time)
    end

    it "captures full event attribute data" do
      app = Hecks.load(domain)
      audit = described_class.new(app.event_bus)

      PizzasDomain::Pizza.create(name: "Hawaiian")

      entry = audit.log.first
      expect(entry[:event_data]).to be_a(Hash)
      expect(entry[:event_data][:name]).to eq("Hawaiian")
    end

    it "records multiple events" do
      app = Hecks.load(domain)
      audit = described_class.new(app.event_bus)

      PizzasDomain::Pizza.create(name: "Margherita")
      PizzasDomain::Pizza.create(name: "Pepperoni")

      expect(audit.log.size).to eq(2)
      expect(audit.log.map { |e| e[:event_data][:name] }).to eq(["Margherita", "Pepperoni"])
    end
  end

  describe "command context via middleware" do
    it "enriches entries with command name, actor, and tenant" do
      app = Hecks.load(domain)
      audit = described_class.new(app.event_bus)
      app.use(:audit) do |cmd, nxt|
        audit.around_command(cmd, nxt, actor: "admin@co.com", tenant: "acme")
      end

      PizzasDomain::Pizza.create(name: "Veggie")

      entry = audit.log.first
      expect(entry[:command]).to eq("CreatePizza")
      expect(entry[:actor]).to eq("admin@co.com")
      expect(entry[:tenant]).to eq("acme")
    end

    it "defaults actor and tenant to nil without middleware" do
      app = Hecks.load(domain)
      audit = described_class.new(app.event_bus)

      PizzasDomain::Pizza.create(name: "Plain")

      entry = audit.log.first
      expect(entry[:actor]).to be_nil
      expect(entry[:tenant]).to be_nil
      expect(entry[:command]).to be_nil
    end
  end

  describe "#clear" do
    it "empties the audit log" do
      app = Hecks.load(domain)
      audit = described_class.new(app.event_bus)

      PizzasDomain::Pizza.create(name: "Test")
      expect(audit.log.size).to eq(1)

      audit.clear
      expect(audit.log).to be_empty
    end
  end
end
