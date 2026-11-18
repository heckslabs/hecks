require "spec_helper"
require "tmpdir"
require_relative "../../support/thread_parking"

# The parse cache, its stamps and the per-tree block index change together: a `forget` racing an
# index build never leaves an entry for a tree the cache has dropped, and a file whose stamp moved
# is read anew.
RSpec.describe Hecks::Adapters::Prism do
  # Other specs parse files through the process-wide cache; start from an empty one.
  before { described_class.forget_all }

  around do |example|
    Dir.mktmpdir("hecks-prism-cache") do |dir|
      @file = File.join(dir, "sample.rb")
      File.write(@file, "[1].each do |n|\n  n + 1\nend\n")
      example.run
    end
    described_class.forget_all
  end

  describe ".forget" do
    it "finds a block by line" do
      expect(described_class.block_node_at(@file, 1)).to be_a(Prism::BlockNode)
    end

    # Runs `block_node_at` while a second thread forgets the file halfway through the index build.
    def index_while_forgetting
      forgetter = nil
      real = described_class.method(:blocks_by_line)
      allow(described_class).to receive(:blocks_by_line) do |tree|
        forgetter = Thread.new { described_class.forget(@file) }
        ThreadParking.wait_until_parked(forgetter)
        real.call(tree)
      end
      described_class.block_node_at(@file, 1)
      forgetter.join(5)
    end

    it "leaves no index entry for a tree forgotten while its index is being built", :aggregate_failures do
      index_while_forgetting

      expect(described_class::TREES).to be_empty
      expect(described_class::BLOCKS_BY_LINE).to be_empty
    end

    it "drops the file's stamp with its tree" do
      described_class.block_node_at(@file, 1)
      described_class.forget(@file)

      expect(described_class::STAMPS).to be_empty
    end
  end

  # A long-lived process whose checkout moves reads each moved file anew: a block on a line the
  # old text did not have is found in the new text, never looked up in the old tree.
  describe ".tree_for" do
    # Replaces the file as a checkout does: new text written beside it, then renamed over it.
    def move_file(text)
      File.write("#{@file}.new", text)
      File.rename("#{@file}.new", @file)
    end

    it "parses a file again once its stamp moved" do
      described_class.block_node_at(@file, 1)
      move_file("# moved\n\n[2].each { |n| n * 2 }\n")

      expect(described_class.block_node_at(@file, 3).body.slice).to eq("n * 2")
    end

    it "keeps a tree set with no stamp, as staged text sets it" do
      staged = Prism.parse("[3].map { |n| n - 3 }\n").value
      described_class::TREES[@file] = staged

      expect(described_class.tree_for(@file)).to be(staged)
    end
  end
end
