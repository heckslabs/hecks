require "spec_helper"
require "tmpdir"
require "fileutils"

# Who the launcher's help is for: someone working on a hecks checkout sees the maintainer's
# commands, anyone else sees what they run against their own project, plus the chapters.
RSpec.describe Hecks::Doors::LauncherOptions do
  let(:root) { Dir.mktmpdir("launcher-audience") }

  after { FileUtils.rm_rf(root) }

  def checkout(at = root)
    FileUtils.mkdir_p(File.join(at, "lib"))
    File.write(File.join(at, "hecks.gemspec"), "")
  end

  describe ".maintainer?" do
    it "is true in a hecks checkout, and in any directory below one", :aggregate_failures do
      checkout
      deep = File.join(root, "lib", "hecks", "doors")
      FileUtils.mkdir_p(deep)

      expect(described_class.maintainer?(root, {})).to be(true)
      expect(described_class.maintainer?(deep, {})).to be(true)
    end

    it "is false in a project that merely has a gemspec of its own name, or no lib beside it" do
      File.write(File.join(root, "shop.gemspec"), "")
      File.write(File.join(root, "hecks.gemspec"), "")

      expect(described_class.maintainer?(root, {})).to be(false)
    end

    it "is false anywhere else" do
      expect(described_class.maintainer?(root, {})).to be(false)
    end

    it "takes HECKS_MAINTAINER as the answer, either way", :aggregate_failures do
      checkout

      expect(described_class.maintainer?(root, "HECKS_MAINTAINER" => "0")).to be(false)
      expect(described_class.maintainer?(Dir.mktmpdir("elsewhere"), "HECKS_MAINTAINER" => "1")).to be(true)
    end
  end

  describe ".audience" do
    let(:setting) { { maintainer: %w[LanguageRun], chapters: %w[Deploy], maintainer_chapters: %w[Bluebook] } }

    it "hides the maintainer's aggregates from anyone else and points at the chapters" do
      expect(described_class.audience(setting, false)).to eq(hide: %w[LanguageRun], chapters: %w[Deploy])
    end

    it "hides nothing from a maintainer, and adds the language's own chapters" do
      expect(described_class.audience(setting, true)).to eq(hide: [], chapters: %w[Deploy Bluebook])
    end

    it "leaves a chapter that did not opt in whole" do
      expect(described_class.audience(nil, false)).to eq({})
    end
  end

  describe "the Hecks chapter's own setting" do
    let(:codebase) do
      File.read(File.expand_path("../../lib/hecks/hecks/codebase.bluebook", __dir__)).scan(/^  aggregate "(\w+)"/).flatten
    end
    let(:hidden) do
      world = File.read(File.expand_path("../../lib/hecks/hecks/hecks.world", __dir__))
      world[/maintainer: %w\[(.*?)\]/m, 1].split
    end

    it "hides exactly the Codebase aggregates and the release ones, nothing a project runs", :aggregate_failures do
      expect(hidden).to include(*codebase)
      expect(hidden - codebase).to contain_exactly("Release", "SyntaxBootCache")
    end
  end
end
