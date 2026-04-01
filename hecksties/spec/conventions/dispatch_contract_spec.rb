require "spec_helper"

RSpec.describe Hecks::Conventions::DispatchContract do
  let(:domain) do
    Hecks.domain "Widget" do
      aggregate "Widget" do
        attribute :name, String

        command "CreateWidget" do
          attribute :name, String
        end

        command "ArchiveWidget" do
          reference_to "Widget"
        end

        query "ByName" do |name|
          where(name: name)
        end
      end
    end
  end

  let(:whitelist) { described_class.build_whitelist(domain) }

  describe ".build_whitelist" do
    it "includes command methods derived from the domain IR" do
      expect(whitelist["Widget"]).to include(:create)
    end

    it "includes transition command methods derived from the domain IR" do
      expect(whitelist["Widget"]).to include(:archive)
    end

    it "includes query methods derived from the domain IR" do
      expect(whitelist["Widget"]).to include(:by_name)
    end

    it "includes all CRUD builtins" do
      described_class::CRUD_BUILTINS.each do |m|
        expect(whitelist["Widget"]).to include(m)
      end
    end

    it "returns Sets (or objects responding to include?)" do
      whitelist.each_value do |allowed|
        expect(allowed).to respond_to(:include?)
      end
    end
  end

  describe ".validate!" do
    it "passes for an allowed method" do
      expect { described_class.validate!(whitelist, "Widget", :create) }.not_to raise_error
    end

    it "raises DispatchNotAllowed for :eval" do
      expect {
        described_class.validate!(whitelist, "Widget", :eval)
      }.to raise_error(described_class::DispatchNotAllowed)
    end

    it "raises DispatchNotAllowed for :system" do
      expect {
        described_class.validate!(whitelist, "Widget", :system)
      }.to raise_error(described_class::DispatchNotAllowed)
    end

    it "raises DispatchNotAllowed for :instance_eval" do
      expect {
        described_class.validate!(whitelist, "Widget", :instance_eval)
      }.to raise_error(described_class::DispatchNotAllowed)
    end

    it "raises for an unknown aggregate name" do
      expect {
        described_class.validate!(whitelist, "UnknownAggregate", :create)
      }.to raise_error(described_class::DispatchNotAllowed)
    end
  end
end
