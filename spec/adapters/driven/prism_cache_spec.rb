require "spec_helper"
require "tmpdir"

# The parse cache and the per-tree block index change together: a `forget` racing an index
# build must never leave an index entry for a tree the cache has dropped.
RSpec.describe Hecks::Adapters::Prism, ".forget" do
  around do |example|
    Dir.mktmpdir("hecks-prism-cache") do |dir|
      @file = File.join(dir, "sample.rb")
      File.write(@file, "[1].each do |n|\n  n + 1\nend\n")
      example.run
    end
    described_class.forget_all
  end

  it "finds a block by line" do
    expect(described_class.block_node_at(@file, 1)).to be_a(Prism::BlockNode)
  end

  it "leaves no index entry for a tree forgotten while its index is being built" do
    forgetter = nil
    real = described_class.method(:blocks_by_line)
    allow(described_class).to receive(:blocks_by_line) do |tree|
      forgetter = Thread.new { described_class.forget(@file) }
      sleep 0.2
      real.call(tree)
    end

    described_class.block_node_at(@file, 1)
    forgetter.join(5)

    expect(described_class::TREES).to be_empty
    expect(described_class::BLOCKS_BY_LINE).to be_empty
  end
end
