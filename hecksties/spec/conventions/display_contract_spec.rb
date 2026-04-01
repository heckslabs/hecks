require "spec_helper"

RSpec.describe Hecks::Conventions::DisplayContract do
  let(:attr_class) { Hecks::DomainModel::Structure::Attribute }

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

  describe ".cell_expression with domain" do
    it "returns short-id fallback when no domain given for reference attr" do
      attr = attr_class.new(name: :model_id, type: String)
      expr = described_class.cell_expression(attr, "obj", lang: :ruby)
      expect(expr).to eq("obj.model_id.to_s")
    end
  end
end
