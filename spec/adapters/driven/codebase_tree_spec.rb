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
    let(:files) { { same => "one\n", other => "new\n", File.join(dir, "fresh/new.txt") => "made\n" } }

    def same = File.join(dir, "same.txt")
    def other = File.join(dir, "other.txt")
    def stale = File.join(dir, "stale.txt")

    before do
      File.write(same, "one\n")
      File.write(other, "old\n")
      File.write(stale, "gone\n")
    end

    context "when not confirmed" do
      let(:report) { tree.apply(files, stale: [stale]) }

      it "reports the drift" do
        expect(report).to include("dry run, 3 files differ (add --confirm to write)",
                                  "changed other.txt", "new fresh/new.txt", "removed stale.txt")
      end

      it "leaves out what already holds its content" do
        expect(report).not_to include("same.txt")
      end

      it "writes nothing" do
        report

        expect([File.read(other), File.exist?(stale), File.exist?(File.join(dir, "fresh/new.txt"))])
          .to eq(["old\n", true, false])
      end
    end

    it "writes the differences, makes the directories and removes what is stale when confirmed", :aggregate_failures do
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
