require "spec_helper"
require "tmpdir"

RSpec.describe Hecks::Generators::Infrastructure::SelfHostDiff do
  let(:domain) do
    Hecks.domain "TestChapter" do
      aggregate "Widget" do
        attribute :name, String

        command "CreateWidget" do
          attribute :name, String
        end
      end
    end
  end

  around do |example|
    Dir.mktmpdir("self_diff_test") do |tmpdir|
      @gem_root = tmpdir
      example.run
    end
  end

  def write_lib_file(relative_path, content)
    path = File.join(@gem_root, "lib", relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  describe "#call" do
    it "classifies files that exist in gem but not in generated output as uncovered" do
      write_lib_file("custom/hand_written.rb", "# custom code")

      diff = described_class.new(domain, gem_root: @gem_root)
      entries = diff.call

      uncovered = entries.select { |e| e.status == :uncovered }
      expect(uncovered.map(&:path)).to include("custom/hand_written.rb")
    end

    it "classifies generated files not in gem as extra" do
      diff = described_class.new(domain, gem_root: @gem_root)
      entries = diff.call

      extra = entries.select { |e| e.status == :extra }
      expect(extra).not_to be_empty
    end

    it "returns entries for all unique paths" do
      write_lib_file("something.rb", "# content")

      diff = described_class.new(domain, gem_root: @gem_root)
      entries = diff.call

      paths = entries.map(&:path)
      expect(paths).to eq(paths.uniq.sort)
    end
  end

  describe "#summary" do
    it "returns grouped counts" do
      diff = described_class.new(domain, gem_root: @gem_root)
      report = diff.summary

      expect(report).to include(:total, :match, :partial, :uncovered, :extra, :entries)
      expect(report[:total]).to eq(report[:entries].size)
    end

    it "counts match when generated and actual are identical" do
      # Generate to tmpdir, then copy a file to the gem root
      gen_dir = Dir.mktmpdir("gen")
      Hecks::Generators::Infrastructure::DomainGemGenerator.new(domain, output_dir: gen_dir).generate
      gem_name = domain.gem_name
      gen_lib = File.join(gen_dir, gem_name, "lib")

      # Copy one generated file to the gem root's lib/
      first_file = Dir.glob(File.join(gen_lib, "**", "*.rb")).first
      relative = first_file.sub("#{gen_lib}/", "")
      write_lib_file(relative, File.read(first_file))

      diff = described_class.new(domain, gem_root: @gem_root)
      report = diff.summary

      expect(report[:match]).to be >= 1
    ensure
      FileUtils.rm_rf(gen_dir)
    end
  end
end
