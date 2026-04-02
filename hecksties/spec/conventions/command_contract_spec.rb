require "spec_helper"

RSpec.describe Hecks::Conventions::CommandContract do
  describe ".method_name" do
    it { expect(described_class.method_name("CreatePolicy", "GovernancePolicy")).to eq(:create) }
    it { expect(described_class.method_name("ActivatePolicy", "GovernancePolicy")).to eq(:activate) }
    it { expect(described_class.method_name("SuspendPolicy", "GovernancePolicy")).to eq(:suspend) }
    it { expect(described_class.method_name("CreatePizza", "Pizza")).to eq(:create) }
    it { expect(described_class.method_name("UpdatePizza", "Pizza")).to eq(:update) }
  end

  describe ".agg_suffixes" do
    it { expect(described_class.agg_suffixes("GovernancePolicy")).to eq(["governance_policy", "policy"]) }
    it { expect(described_class.agg_suffixes("Pizza")).to eq(["pizza"]) }
    it { expect(described_class.agg_suffixes("governance_policy")).to eq(["governance_policy", "policy"]) }
  end

  describe ".reference_attribute?" do
    it { expect(described_class.reference_attribute?("policy_id", "GovernancePolicy")).to be true }
    it { expect(described_class.reference_attribute?("governance_policy_id", "GovernancePolicy")).to be true }
    it { expect(described_class.reference_attribute?("pizza_id", "Pizza")).to be true }
    it { expect(described_class.reference_attribute?("name", "GovernancePolicy")).to be false }
    it { expect(described_class.reference_attribute?("other_id", "Pizza")).to be false }
    it { expect(described_class.reference_attribute?(:policy_id, "GovernancePolicy")).to be true }
  end

  describe ".find_self_ref" do
    let(:policy_id) { double(name: "policy_id") }
    let(:name_attr) { double(name: "name") }
    let(:other_id) { double(name: "other_id") }

    it "returns the matching attribute" do
      expect(described_class.find_self_ref([name_attr, policy_id], "GovernancePolicy")).to eq(policy_id)
    end

    it "returns nil when no match" do
      expect(described_class.find_self_ref([name_attr, other_id], "GovernancePolicy")).to be_nil
    end

    it "returns nil for an empty list" do
      expect(described_class.find_self_ref([], "Pizza")).to be_nil
    end
  end
end
