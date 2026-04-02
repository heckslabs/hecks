require "spec_helper"

RSpec.describe Hecks::Conventions::DisplayContract do
  let(:domain) { BootedDomains.pizzas }
  let(:attr_class) { Hecks::DomainModel::Structure::Attribute }

  describe ".home_aggregate_data" do
    it "returns command_names as a humanized comma-separated string" do
      pizza = domain.aggregates.find { |a| a.name == "Pizza" }
      data = described_class.home_aggregate_data(pizza, "pizzas")
      expect(data[:command_names]).to include("Create Pizza")
      expect(data[:command_names]).to include("Add Topping")
    end

    it "returns an empty string when there are no commands" do
      agg = double("agg",
        name: "Empty",
        commands: [],
        attributes: [],
        policies: [])
      data = described_class.home_aggregate_data(agg, "empties")
      expect(data[:command_names]).to eq("")
    end

    it "does not count hidden attributes in the attribute count" do
      visible_attr = attr_class.new(name: :name, type: String)
      hidden_attr  = attr_class.new(name: :password_digest, type: String, visible: false)
      agg = double("agg",
        name: "Account",
        commands: [],
        attributes: [visible_attr, hidden_attr],
        policies: [])
      data = described_class.home_aggregate_data(agg, "accounts")
      expect(data[:attributes]).to eq(1)
    end
  end

  describe ".reference_attr?" do
    it "returns true for _id String attrs" do
      attr = attr_class.new(name: :model_id, type: String)
      expect(described_class.reference_attr?(attr)).to be true
    end

    it "returns false for non-_id attrs" do
      attr = attr_class.new(name: :name, type: String)
      expect(described_class.reference_attr?(attr)).to be false
    end

    it "returns false for _id attrs with non-String type" do
      attr = attr_class.new(name: :model_id, type: Integer)
      expect(described_class.reference_attr?(attr)).to be false
    end

    it "returns false for list _id attrs" do
      attr = attr_class.new(name: :model_id, type: String, list: true)
      expect(described_class.reference_attr?(attr)).to be false
    end
  end

  describe ".reference_column_label" do
    it "strips _id and humanizes" do
      attr = attr_class.new(name: :model_id, type: String)
      expect(described_class.reference_column_label(attr)).to eq("Model")
    end

    it "handles multi-word references" do
      attr = attr_class.new(name: :pizza_topping_id, type: String)
      expect(described_class.reference_column_label(attr)).to eq("Pizza Topping")
    end
  end

  describe ".strip_id_suffix" do
    it "removes _id from a reference field name" do
      expect(described_class.strip_id_suffix("pizza_id")).to eq("pizza")
    end

    it "leaves non-_id names unchanged" do
      expect(described_class.strip_id_suffix("name")).to eq("name")
    end
  end

  describe ".cell_expression with domain" do
    it "returns short-id fallback when no domain given for reference attr" do
      attr = attr_class.new(name: :model_id, type: String)
      expr = described_class.cell_expression(attr, "obj", lang: :ruby)
      expect(expr).to eq("obj.model_id.to_s")
    end
  end
end
