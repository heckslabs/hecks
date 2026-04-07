require "spec_helper"
require "tmpdir"
require "hecks/chapters/hecksagon"

RSpec.describe Hecks::Generators::Infrastructure::FrameworkGemGenerator do
  subject(:gen) { described_class.new(domain, gem_root: gem_root) }

  let(:domain) { Hecks::Chapters::Hecksagon.definition }
  let(:gem_root) { File.expand_path("../../../hecksagon", __dir__) }

  describe "#located_aggregates" do
    it "locates most hecksagon aggregates to actual files" do
      located = gen.located_aggregates
      expect(located.size).to be >= 20
    end

    it "maps GateBuilder to hecksagon/dsl/gate_builder.rb" do
      located = gen.located_aggregates
      gate = located.find { |l| l[:aggregate] == "GateBuilder" }
      expect(gate[:path]).to eq("hecksagon/dsl/gate_builder.rb")
    end
  end

  describe "#unlocated_aggregates" do
    it "returns a small number of unlocated aggregates" do
      expect(gen.unlocated_aggregates.size).to be <= 5
    end
  end

  describe "#generate" do
    it "produces skeleton files in the output directory" do
      Dir.mktmpdir("fw_gen_test") do |tmpdir|
        files = gen.generate(output_dir: tmpdir)

        expect(files).not_to be_empty
        files.each do |rel_path, content|
          expect(File.exist?(File.join(tmpdir, rel_path))).to be true
          # Entry point files are module stubs without methods
          next if rel_path.count("/").zero?
          expect(content).to include("def ")
        end
      end
    end

    it "generates doc comments from aggregate descriptions" do
      Dir.mktmpdir("fw_gen_test") do |tmpdir|
        files = gen.generate(output_dir: tmpdir)
        gate_file = files["hecksagon/dsl/gate_builder.rb"]
        expect(gate_file).to include("DSL builder for access control gates")
      end
    end

    it "generates method stubs from commands" do
      Dir.mktmpdir("fw_gen_test") do |tmpdir|
        files = gen.generate(output_dir: tmpdir)
        gate_file = files["hecksagon/dsl/gate_builder.rb"]
        expect(gate_file).to include("def allow")
        expect(gate_file).to include("def build")
      end
    end
  end
end

RSpec.describe Hecks::Generators::Infrastructure::FrameworkGemGenerator::FileLocator do
  let(:gem_root) { File.expand_path("../../../hecksagon", __dir__) }
  subject(:locator) { described_class.new(gem_root) }

  it "locates GateDefinition to structure/gate_definition.rb" do
    expect(locator.locate("GateDefinition")).to eq("hecksagon/structure/gate_definition.rb")
  end

  it "locates HecksSqlite via prefix stripping" do
    expect(locator.locate("HecksSqlite")).to eq("hecks/extensions/sqlite.rb")
  end

  it "returns nil for unknown aggregates" do
    expect(locator.locate("NonExistentThing")).to be_nil
  end
end
