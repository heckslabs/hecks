# breaking_bumper_spec.rb — HEC-459
#
# Specs for auto-bumping domain version on breaking changes.
#
require "spec_helper"
require "tmpdir"

RSpec.describe Hecks::DomainVersioning::BreakingBumper do
  let(:base_dir) { Dir.mktmpdir("hecks_bump_") }
  after { FileUtils.rm_rf(base_dir) }

  let(:versioner) { Hecks::Versioner.new(base_dir) }

  let(:domain_v1) do
    Hecks.domain "Banking" do
      aggregate "Account" do
        attribute :name, String
        attribute :balance, Integer

        command "CreateAccount" do
          attribute :name, String
        end

        command "CloseAccount" do
          attribute :name, String
        end
      end
    end
  end

  let(:domain_v2_non_breaking) do
    Hecks.domain "Banking" do
      aggregate "Account" do
        attribute :name, String
        attribute :balance, Integer
        attribute :tags, String

        command "CreateAccount" do
          attribute :name, String
        end

        command "CloseAccount" do
          attribute :name, String
        end
      end
    end
  end

  let(:domain_v2_breaking) do
    Hecks.domain "Banking" do
      aggregate "Account" do
        attribute :name, String
        attribute :balance, Integer

        command "CreateAccount" do
          attribute :name, String
        end

        command "FreezeAccount" do
          attribute :name, String
        end
      end
    end
  end

  context "when there is no previous snapshot" do
    it "bumps the version without flagging breaking changes" do
      result = described_class.call(nil, domain_v1, versioner)
      expect(result[:bumped]).to be false
      expect(result[:breaking_changes]).to be_empty
      expect(result[:version]).not_to be_nil
    end
  end

  context "when changes are non-breaking" do
    it "does not bump the version" do
      # Establish a current version first
      versioner.next

      result = described_class.call(domain_v1, domain_v2_non_breaking, versioner)
      expect(result[:bumped]).to be false
      expect(result[:breaking_changes]).to be_empty
    end

    it "returns the current version" do
      current = versioner.next

      result = described_class.call(domain_v1, domain_v2_non_breaking, versioner)
      expect(result[:version]).to eq(current)
    end
  end

  context "when changes are breaking" do
    it "bumps the version" do
      versioner.next

      result = described_class.call(domain_v1, domain_v2_breaking, versioner)
      expect(result[:bumped]).to be true
      expect(result[:version]).not_to be_nil
    end

    it "returns the breaking changes" do
      versioner.next

      result = described_class.call(domain_v1, domain_v2_breaking, versioner)
      expect(result[:breaking_changes]).not_to be_empty
      expect(result[:breaking_changes].all? { |c| c[:breaking] }).to be true
    end

    it "includes the removed command in breaking changes" do
      versioner.next

      result = described_class.call(domain_v1, domain_v2_breaking, versioner)
      labels = result[:breaking_changes].map { |c| c[:label] }
      expect(labels.any? { |l| l.include?("CloseAccount") }).to be true
    end
  end
end
