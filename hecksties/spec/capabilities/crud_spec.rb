require "spec_helper"

RSpec.describe "CRUD capability" do
  let(:domain) do
    Hecks.domain "CrudTest" do
      aggregate "Widget" do
        attribute :name, String
        attribute :color, String
        command "CreateWidget" do
          attribute :name, String
          attribute :color, String
        end
      end
    end
  end

  describe "without capability" do
    it "has only user-defined commands" do
      Hecks.load(domain)
      cmds = domain.aggregates.first.commands.map(&:name)
      expect(cmds).to eq(["CreateWidget"])
    end
  end

  describe "with capability" do
    before do
      @runtime = Hecks.load(domain)
      @runtime.capability(:crud)
    end

    it "generates UpdateWidget and DeleteWidget stubs" do
      cmds = domain.aggregates.first.commands.map(&:name)
      expect(cmds).to include("UpdateWidget", "DeleteWidget")
    end

    it "skips user-defined CreateWidget" do
      create_cmd = domain.aggregates.first.commands.find { |c| c.name == "CreateWidget" }
      # User-defined CreateWidget has name + color attrs (not the auto-gen which would include all)
      expect(create_cmd.attributes.map(&:name)).to eq(%i[name color])
    end

    it "does not generate ReadWidget (handled by repository)" do
      cmds = domain.aggregates.first.commands.map(&:name)
      expect(cmds).not_to include("ReadWidget")
    end

    it "generates corresponding events" do
      events = domain.aggregates.first.events.map(&:name)
      expect(events).to include("UpdatedWidget", "DeletedWidget")
    end

    it "can create, update, and delete via commands" do
      klass = Object.const_get("CrudTestDomain::Widget")
      created = klass.create(name: "Bolt", color: "Silver")
      expect(klass.count).to eq(1)

      klass.update(widget: created.id, name: "Nut", color: "Gold")
      found = klass.find(created.id)
      expect(found.name).to eq("Nut")
      expect(found.color).to eq("Gold")

      klass.delete(widget: created.id)
      expect(klass.count).to eq(0)
    end

    it "binds repository methods (find, all, count, first, last)" do
      klass = Object.const_get("CrudTestDomain::Widget")
      klass.create(name: "A", color: "Red")
      klass.create(name: "B", color: "Blue")
      expect(klass.count).to eq(2)
      expect(klass.first.name).to eq("A")
      expect(klass.last.name).to eq("B")
      expect(klass.all.size).to eq(2)
    end
  end
end
