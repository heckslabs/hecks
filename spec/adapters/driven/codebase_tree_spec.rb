require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/hecks/adapters/codebase/source_tree"

RSpec.describe Hecks::Adapters::Codebase::Tree do
  let(:dir) { Dir.mktmpdir("codebase_tree") }

  after do
    described_class.root = nil
    FileUtils.rm_rf(dir)
  end

  def checkout!
    FileUtils.mkdir_p(File.join(dir, "lib"))
    File.write(File.join(dir, "hecks.gemspec"), "")
  end

  describe "the checkout rule" do
    it "takes this repository for a checkout" do
      expect(described_class.new).to be_checkout
    end

    it "takes a tree with hecks.gemspec beside lib/ for a checkout" do
      checkout!

      expect(described_class.new(root: dir)).to be_checkout
    end

    it "does not take an installed package for one: lib/ without the gemspec" do
      FileUtils.mkdir_p(File.join(dir, "lib"))

      expect(described_class.new(root: dir)).not_to be_checkout
    end

    it "does not take a gemspec without lib/ for one" do
      File.write(File.join(dir, "hecks.gemspec"), "")

      expect(described_class.new(root: dir)).not_to be_checkout
    end

    it "refuses with the words `needs a hecks checkout`, as the runtime's own unmet rule" do
      expect { described_class.new(root: dir).require_checkout! }
        .to raise_error(Hecks::Runtime::GivenNotMet, /needs a hecks checkout/)
    end

    it "reads the root a spec points it at" do
      described_class.root = dir

      expect(described_class.new.root).to eq(File.expand_path(dir))
    end
  end

  describe "#apply" do
    let(:tree) { described_class.new(root: dir) }
    let(:same)  { File.join(dir, "same.txt") }
    let(:other) { File.join(dir, "other.txt") }
    let(:stale) { File.join(dir, "stale.txt") }

    before do
      File.write(same, "one\n")
      File.write(other, "old\n")
      File.write(stale, "gone\n")
    end

    let(:files) { { same => "one\n", other => "new\n", File.join(dir, "fresh/new.txt") => "made\n" } }

    it "reports the drift and writes nothing unless confirmed" do
      report = tree.apply(files, stale: [stale])

      expect(report).to include("dry run, 3 files differ (add --confirm to write)")
      expect(report).to include("changed other.txt", "new fresh/new.txt", "removed stale.txt")
      expect(report).not_to include("same.txt")
      expect(File.read(other)).to eq("old\n")
      expect(File.exist?(stale)).to be(true)
      expect(File.exist?(File.join(dir, "fresh/new.txt"))).to be(false)
    end

    it "writes the differences, makes the directories and removes what is stale when confirmed" do
      report = tree.apply(files, stale: [stale], confirm: true)

      expect(report).to start_with("wrote 3 files:")
      expect(File.read(other)).to eq("new\n")
      expect(File.read(File.join(dir, "fresh/new.txt"))).to eq("made\n")
      expect(File.exist?(stale)).to be(false)
    end

    it "says so when nothing differs" do
      report = tree.apply({ same => "one\n" }, confirm: true)

      expect(report).to eq("nothing to change: 1 files already hold what the language projects")
    end
  end
end

RSpec.describe Hecks::Adapters::SourceTree do
  subject(:adapter) { described_class.new }

  after { Hecks::Adapters::Codebase::Tree.root = nil }

  it "reports that this repository is a checkout" do
    expect(adapter.examine).to eq(checkout: { value: true })
  end

  it "reports that a tree without the gemspec is not one" do
    Dir.mktmpdir do |dir|
      Hecks::Adapters::Codebase::Tree.root = dir

      expect(adapter.examine).to eq(checkout: { value: false })
    end
  end

  it "refuses to carry anything out, and to answer a query, outside a checkout" do
    Dir.mktmpdir do |dir|
      Hecks::Adapters::Codebase::Tree.root = dir

      expect { adapter.perform(operation: { value: "project_model" }) }
        .to raise_error(Hecks::Runtime::GivenNotMet, /needs a hecks checkout/)
      expect { adapter.word_status }.to raise_error(Hecks::Runtime::GivenNotMet, /needs a hecks checkout/)
    end
  end

  it "refuses an operation no task family carries out" do
    expect { adapter.perform(operation: { value: "no_such_operation" }) }
      .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /no task carries out/)
  end
end
