require "spec_helper"
require "hecks/extensions/logging"
require "hecks/extensions/tenancy"
require "hecks/extensions/audit"

RSpec.describe Hecks::Conventions::ExtensionContract do
  describe ".shape" do
    it "returns the expected interface shape" do
      shape = described_class.shape
      expect(shape).to have_key(:describe_extension)
      expect(shape).to have_key(:register_extension)
      expect(shape[:describe_extension][:required_keys]).to eq(%i[description adapter_type wires_to])
      expect(shape[:register_extension][:boot_hook_arity]).to eq(3)
    end
  end

  describe ".validate" do
    it "passes for a well-formed extension like :logging" do
      result = described_class.validate(:logging)
      expect(result[:valid]).to be true
      expect(result[:missing]).to be_empty
    end

    it "passes for a driven extension like :audit" do
      result = described_class.validate(:audit)
      expect(result[:valid]).to be true
    end

    it "passes for a driven extension like :tenancy" do
      result = described_class.validate(:tenancy)
      expect(result[:valid]).to be true
    end

    it "fails for an unregistered extension" do
      result = described_class.validate(:bogus_nonexistent)
      expect(result[:valid]).to be false
      expect(result[:missing]).to include("describe_extension not called for :bogus_nonexistent")
      expect(result[:missing]).to include("register_extension not called for :bogus_nonexistent")
    end
  end

  describe ".validate — metadata-only registration" do
    around do |example|
      Hecks.describe_extension(:test_meta_only,
        description: "Test extension",
        adapter_type: :driven,
        config: {},
        wires_to: :command_bus)
      example.run
      Hecks.extension_meta.delete(:test_meta_only)
    end

    it "fails when register_extension is missing" do
      result = described_class.validate(:test_meta_only)
      expect(result[:valid]).to be false
      expect(result[:missing]).to include("register_extension not called for :test_meta_only")
    end
  end

  describe ".validate — hook-only registration" do
    around do |example|
      Hecks.register_extension(:test_hook_only) { |_dm, _d, _r| }
      example.run
      Hecks.extension_registry.delete(:test_hook_only)
    end

    it "fails when describe_extension is missing" do
      result = described_class.validate(:test_hook_only)
      expect(result[:valid]).to be false
      expect(result[:missing]).to include("describe_extension not called for :test_hook_only")
    end
  end

  describe ".validate — invalid adapter_type" do
    around do |example|
      Hecks.describe_extension(:test_bad_type,
        description: "Bad type",
        adapter_type: :bogus,
        config: {},
        wires_to: :command_bus)
      Hecks.register_extension(:test_bad_type) { |_dm, _d, _r| }
      example.run
      Hecks.extension_meta.delete(:test_bad_type)
      Hecks.extension_registry.delete(:test_bad_type)
    end

    it "reports invalid adapter_type" do
      result = described_class.validate(:test_bad_type)
      expect(result[:valid]).to be false
      expect(result[:missing]).to include("metadata for :test_bad_type has invalid adapter_type: :bogus")
    end
  end

  describe ".validate_all" do
    it "returns results for all known extensions" do
      results = described_class.validate_all
      expect(results).to be_a(Hash)
      expect(results.keys).to include(:logging)
      results.each_value do |result|
        expect(result).to have_key(:valid)
        expect(result).to have_key(:missing)
      end
    end
  end

  describe ".all_extension_names" do
    it "includes known extensions" do
      names = described_class.all_extension_names
      expect(names).to include(:logging, :tenancy, :audit)
    end

    it "returns sorted unique symbols" do
      names = described_class.all_extension_names
      expect(names).to eq(names.sort)
      expect(names).to eq(names.uniq)
    end
  end

  describe "VALID_ADAPTER_TYPES" do
    it "includes :driven and :driving" do
      expect(described_class::VALID_ADAPTER_TYPES).to eq(%i[driven driving])
    end
  end
end
