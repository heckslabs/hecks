require "spec_helper"
require "hecks/extensions/web_explorer/ir_introspector"
require "hecks/extensions/web_explorer/runtime_bridge"
require "hecks/extensions/web_explorer/renderer"

RSpec.describe "Web Explorer IR introspection" do
  let(:domain) { BootedDomains.pizzas }
  let(:ir) { Hecks::WebExplorer::IRIntrospector.new(domain) }

  describe Hecks::WebExplorer::IRIntrospector do
    it "returns aggregate names from the IR" do
      expect(ir.aggregate_names).to eq(["Pizza", "Order"])
    end

    it "finds an aggregate by name" do
      agg = ir.find_aggregate("Pizza")
      expect(agg).not_to be_nil
      expect(agg.name).to eq("Pizza")
    end

    it "returns user attributes (excludes reserved)" do
      agg = ir.find_aggregate("Pizza")
      names = ir.user_attributes(agg).map(&:name)
      expect(names).to include(:name, :style)
      expect(names).not_to include(:id, :created_at, :updated_at)
    end

    it "returns columns from IR attribute definitions" do
      agg = ir.find_aggregate("Pizza")
      columns = ir.columns_for(agg)
      labels = columns.map { |c| c[:label] }
      expect(labels).to include("Name", "Style", "Description")
    end

    it "returns create commands from the IR" do
      agg = ir.find_aggregate("Pizza")
      cmds = ir.create_commands(agg)
      expect(cmds.map(&:name)).to eq(["CreatePizza"])
    end

    it "finds a command by snake name" do
      agg = ir.find_aggregate("Pizza")
      cmd = ir.find_command(agg, "create_pizza")
      expect(cmd).not_to be_nil
      expect(cmd.name).to eq("CreatePizza")
    end

    it "builds command form fields from IR command attributes" do
      agg = ir.find_aggregate("Pizza")
      cmd = ir.find_command(agg, "create_pizza")
      fields = ir.command_fields(cmd)
      names = fields.map { |f| f[:name] }
      expect(names).to include("name", "style", "description", "price")
    end

    it "pre-fills command fields from params" do
      agg = ir.find_aggregate("Pizza")
      cmd = ir.find_command(agg, "create_pizza")
      fields = ir.command_fields(cmd, { "name" => "Margherita" })
      name_field = fields.find { |f| f[:name] == "name" }
      expect(name_field[:value]).to eq("Margherita")
    end

    it "detects reference attributes via IR" do
      attr_class = Hecks::DomainModel::Structure::Attribute
      ref_attr = attr_class.new(name: :pizza_id, type: String)
      expect(ir.reference_attr?(ref_attr)).to be true
    end

    it "finds referenced aggregate by IR lookup" do
      attr_class = Hecks::DomainModel::Structure::Attribute
      ref_attr = attr_class.new(name: :pizza_id, type: String)
      ref = ir.find_referenced_aggregate(ref_attr)
      expect(ref).not_to be_nil
      expect(ref.name).to eq("Pizza")
    end

    it "excludes hidden attributes from user_attributes" do
      attr_class = Hecks::DomainModel::Structure::Attribute
      hidden = attr_class.new(name: :secret, type: String, visible: false)
      visible = attr_class.new(name: :label, type: String)
      agg = double("agg", attributes: [hidden, visible])
      result = ir.user_attributes(agg)
      expect(result.map(&:name)).to eq([:label])
      expect(result.map(&:name)).not_to include(:secret)
    end

    it "excludes hidden attributes from columns_for" do
      attr_class = Hecks::DomainModel::Structure::Attribute
      hidden = attr_class.new(name: :token, type: String, visible: false)
      visible = attr_class.new(name: :title, type: String)
      agg = double("agg", attributes: [hidden, visible], computed_attributes: [])
      cols = ir.columns_for(agg)
      labels = cols.map { |c| c[:label] }
      expect(labels).to include("Title")
      expect(labels).not_to include("Token")
    end

    it "returns policy labels from the IR" do
      labels = ir.policy_labels
      expect(labels).to include("PlacedOrder \u2192 ReserveIngredients")
    end

    it "returns available roles from the IR" do
      roles = ir.available_roles
      expect(roles).to be_an(Array)
      expect(roles).not_to be_empty
    end

    it "builds home aggregate data from the IR" do
      agg = ir.find_aggregate("Pizza")
      data = ir.home_aggregate_data(agg, "pizzas")
      expect(data[:name]).to eq("Pizzas")
      expect(data[:command_names]).to include("Create Pizza")
      expect(data[:attributes]).to be_a(Integer)
    end

    it "returns diagram_data with structure, behavior, and flows" do
      data = ir.diagram_data
      expect(data[:structure_diagram]).to include("classDiagram")
      expect(data[:structure_diagram]).to include("Pizza")
      expect(data[:behavior_diagram]).to include("flowchart LR")
      expect(data[:flows_diagram]).to include("sequenceDiagram")
    end
  end

  describe Hecks::WebExplorer::Renderer do
    let(:views_dir) { File.expand_path("../../lib/hecks/extensions/web_explorer/views", __dir__) }
    let(:renderer) { Hecks::WebExplorer::Renderer.new(views_dir) }

    it "escapes HTML special characters via h()" do
      expect(renderer.h("<script>alert(1)</script>")).to eq("&lt;script&gt;alert(1)&lt;/script&gt;")
    end
  end

  describe Hecks::WebExplorer::RuntimeBridge do
    let(:bridge_domain) do
      Hecks.domain "BridgeTest" do
        aggregate "Widget" do
          attribute :label, String
          command "CreateWidget" do
            attribute :label, String
          end
        end
      end
    end
    let(:bridge_mod) { Hecks.load(bridge_domain); BridgeTestDomain }
    let(:bridge) { Hecks::WebExplorer::RuntimeBridge.new(bridge_mod) }

    it "finds all records via the bridge" do
      bridge.execute_command("Widget", :create, { label: "A" })
      all = bridge.find_all("Widget")
      expect(all).not_to be_empty
    end

    it "finds a record by id via the bridge" do
      id = bridge.execute_command("Widget", :create, { label: "Lookup" })
      obj = bridge.find_by_id("Widget", id)
      expect(obj).not_to be_nil
      expect(bridge.read_attribute(obj, :label)).to eq("Lookup")
    end

    it "executes commands and returns the id" do
      id = bridge.execute_command("Widget", :create, { label: "Exec" })
      expect(id).to be_a(String)
      expect(id).not_to be_empty
    end

    it "does not expose Object.const_get to the UI layer" do
      # RuntimeBridge encapsulates const_get internally -- the UI never
      # resolves module constants directly
      expect(bridge).to respond_to(:find_all)
      expect(bridge).to respond_to(:find_by_id)
      expect(bridge).not_to respond_to(:klass_for)
    end
  end
end
