# = UILabelContract spec
#
# Covers label conversion and the inline pluralizer that replaced
# ActiveSupport::String#pluralize (HEC-454).

require "spec_helper"

RSpec.describe Hecks::Conventions::UILabelContract do
  describe ".label" do
    it "humanizes snake_case field names" do
      expect(described_class.label(:effective_date)).to eq("Effective Date")
    end

    it "splits PascalCase command names" do
      expect(described_class.label("ReportIncident")).to eq("Report Incident")
    end

    it "handles single-word strings" do
      expect(described_class.label("Pizza")).to eq("Pizza")
    end

    it "handles consecutive capitals (e.g. UILabel)" do
      expect(described_class.label("UILabel")).to eq("Ui Label")
    end

    it "strips trailing _id — pizza_id becomes Pizza" do
      expect(described_class.label(:pizza_id)).to eq("Pizza")
    end

    it "strips trailing _id — restaurant_id becomes Restaurant" do
      expect(described_class.label(:restaurant_id)).to eq("Restaurant")
    end

    it "strips trailing _id — multi-word pizza_topping_id becomes Pizza Topping" do
      expect(described_class.label(:pizza_topping_id)).to eq("Pizza Topping")
    end

    it "does not strip Id in the middle of a name" do
      expect(described_class.label("Provider")).to eq("Provider")
    end
  end

  describe ".plural_label" do
    it "pluralizes the last word — regular noun" do
      expect(described_class.plural_label("Order")).to eq("Orders")
    end

    it "pluralizes the last word — consonant+y → ies" do
      expect(described_class.plural_label("GovernancePolicy")).to eq("Governance Policies")
    end

    it "pluralizes the last word — ends in ch → es" do
      expect(described_class.plural_label("Dispatch")).to eq("Dispatches")
    end

    it "pluralizes the last word — ends in sh → es" do
      expect(described_class.plural_label("Dish")).to eq("Dishes")
    end

    it "pluralizes the last word — ends in x → es" do
      expect(described_class.plural_label("Index")).to eq("Indexes")
    end

    it "leaves earlier words singular" do
      expect(described_class.plural_label("GovernancePolicy")).to eq("Governance Policies")
    end
  end

  describe ".pluralize" do
    it "adds s for regular words" do
      expect(described_class.pluralize("Pizza")).to eq("Pizzas")
    end

    it "adds es for words ending in s" do
      expect(described_class.pluralize("Status")).to eq("Statuses")
    end

    it "adds es for words ending in x" do
      expect(described_class.pluralize("Box")).to eq("Boxes")
    end

    it "adds es for words ending in z" do
      expect(described_class.pluralize("Topaz")).to eq("Topazes")
    end

    it "adds es for words ending in ch" do
      expect(described_class.pluralize("Batch")).to eq("Batches")
    end

    it "adds es for words ending in sh" do
      expect(described_class.pluralize("Brush")).to eq("Brushes")
    end

    it "replaces y with ies for consonant+y words" do
      expect(described_class.pluralize("Category")).to eq("Categories")
    end

    it "replaces y with ies for Policy" do
      expect(described_class.pluralize("Policy")).to eq("Policies")
    end

    it "adds s for vowel+y words (e.g. Day)" do
      expect(described_class.pluralize("Day")).to eq("Days")
    end
  end
end
