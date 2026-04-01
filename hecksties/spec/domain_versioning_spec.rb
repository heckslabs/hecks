# domain_versioning_spec.rb — HEC-455
#
# Specs for domain interface versioning: tag, log, load, diff,
# and breaking change classification.
#
require "spec_helper"
require "tmpdir"

RSpec.describe Hecks::DomainVersioning do
  let(:base_dir) { Dir.mktmpdir("hecks_ver_") }
  after { FileUtils.rm_rf(base_dir) }

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

  let(:domain_v2) do
    Hecks.domain "Banking" do
      aggregate "Account" do
        attribute :name, String
        attribute :balance, Integer
        attribute :tags, String

        command "CreateAccount" do
          attribute :name, String
        end

        command "FreezeAccount" do
          attribute :name, String
        end
      end
    end
  end

  describe ".tag" do
    it "writes a snapshot file with metadata header" do
      path = described_class.tag("1.0.0", domain_v1, base_dir: base_dir)
      expect(File.exist?(path)).to be true
      content = File.read(path)
      expect(content).to include("# version: 1.0.0")
      expect(content).to include("# tagged_at: #{Date.today}")
      expect(content).to include('Hecks.domain "Banking"')
    end

    it "creates the db/hecks_versions directory" do
      described_class.tag("1.0.0", domain_v1, base_dir: base_dir)
      expect(File.directory?(File.join(base_dir, "db/hecks_versions"))).to be true
    end
  end

  describe ".exists?" do
    it "returns false when no snapshot exists" do
      expect(described_class.exists?("1.0.0", base_dir: base_dir)).to be false
    end

    it "returns true after tagging" do
      described_class.tag("1.0.0", domain_v1, base_dir: base_dir)
      expect(described_class.exists?("1.0.0", base_dir: base_dir)).to be true
    end
  end

  describe ".log" do
    it "returns empty array when no versions exist" do
      expect(described_class.log(base_dir: base_dir)).to eq([])
    end

    it "lists versions newest first" do
      described_class.tag("1.0.0", domain_v1, base_dir: base_dir)
      described_class.tag("2.0.0", domain_v2, base_dir: base_dir)
      entries = described_class.log(base_dir: base_dir)
      expect(entries.map { |e| e[:version] }).to eq(["2.0.0", "1.0.0"])
    end

    it "includes tagged_at date" do
      described_class.tag("1.0.0", domain_v1, base_dir: base_dir)
      entries = described_class.log(base_dir: base_dir)
      expect(entries.first[:tagged_at]).to eq(Date.today.to_s)
    end
  end

  describe ".load_version" do
    it "returns nil for nonexistent version" do
      expect(described_class.load_version("9.9.9", base_dir: base_dir)).to be_nil
    end

    it "loads a tagged domain snapshot" do
      described_class.tag("1.0.0", domain_v1, base_dir: base_dir)
      loaded = described_class.load_version("1.0.0", base_dir: base_dir)
      expect(loaded).not_to be_nil
      expect(loaded.name).to eq("Banking")
      expect(loaded.aggregates.first.commands.map(&:name)).to include("CloseAccount")
    end
  end

  describe ".latest_version" do
    it "returns nil when no versions exist" do
      expect(described_class.latest_version(base_dir: base_dir)).to be_nil
    end

    it "returns the newest version" do
      described_class.tag("1.0.0", domain_v1, base_dir: base_dir)
      described_class.tag("2.0.0", domain_v2, base_dir: base_dir)
      expect(described_class.latest_version(base_dir: base_dir)).to eq("2.0.0")
    end
  end
end

RSpec.describe Hecks::DomainVersioning::BreakingClassifier do
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

  let(:domain_v2) do
    Hecks.domain "Banking" do
      aggregate "Account" do
        attribute :name, String
        attribute :balance, Integer
        attribute :tags, String

        command "CreateAccount" do
          attribute :name, String
        end

        command "FreezeAccount" do
          attribute :name, String
        end
      end
    end
  end

  let(:changes) { Hecks::Migrations::DomainDiff.call(domain_v1, domain_v2) }
  let(:classified) { described_class.classify(changes) }

  it "classifies added attributes as non-breaking" do
    added_attr = classified.find { |c| c[:change].kind == :add_attribute }
    expect(added_attr[:breaking]).to be false
  end

  it "classifies removed commands as breaking" do
    removed_cmd = classified.find { |c| c[:change].kind == :remove_command }
    expect(removed_cmd).not_to be_nil
    expect(removed_cmd[:breaking]).to be true
  end

  it "classifies added commands as non-breaking" do
    added_cmd = classified.find { |c| c[:change].kind == :add_command }
    expect(added_cmd[:breaking]).to be false
  end

  it "formats labels with aggregate and detail names" do
    added_attr = classified.find { |c| c[:change].kind == :add_attribute }
    expect(added_attr[:label]).to include("Account")
    expect(added_attr[:label]).to include("tags")
  end

  it "marks removed commands with BREAKING in label context" do
    removed_cmd = classified.find { |c| c[:change].kind == :remove_command }
    expect(removed_cmd[:label]).to include("CloseAccount")
  end
end
