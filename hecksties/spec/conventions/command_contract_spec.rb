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
end
