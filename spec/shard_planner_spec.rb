require "spec_helper"
require "hecks/tools/shard_planner"

# The split every sharded CI family shares: a pure function of the items, the shard count and the
# prices, so every leg that computes it agrees.
RSpec.describe Hecks::Tools::ShardPlanner do
  let(:sizes) { :size.to_proc }
  let(:files) { (1..12).map { |number| "spec/f#{number}_spec.rb" } }

  def skewed_table = files.to_h { |file| [file, file == files.first ? 60.0 : 1.0] }

  def load_of(group, table) = group.sum { |file| table.fetch(file) }

  describe ".parse" do
    it "reads path:seconds lines, exponent form included", :aggregate_failures do
      table = described_class.parse("spec/a_spec.rb:1.5\nspec/b_spec.rb:9.69e-05\n")

      expect(table).to eq("spec/a_spec.rb" => 1.5, "spec/b_spec.rb" => 9.69e-05)
    end

    it "skips lines that are not timings" do
      text = "Run options: exclude {:io=>true}\nnot a line\nspec/a_spec.rb:oops\nspec/ok_spec.rb:2\n\n"

      expect(described_class.parse(text)).to eq("spec/ok_spec.rb" => 2.0)
    end

    it "reads nothing from nothing", :aggregate_failures do
      expect(described_class.parse(nil)).to eq({})
      expect(described_class.parse("")).to eq({})
    end
  end

  describe ".merge" do
    it "joins several shards' logs into one table" do
      logs = ["spec/a_spec.rb:1\n", "spec/b_spec.rb:2\n"]

      expect(described_class.merge(logs)).to eq("spec/a_spec.rb" => 1.0, "spec/b_spec.rb" => 2.0)
    end
  end

  describe ".prices" do
    it "prices an item the table lacks at the table's median", :aggregate_failures do
      prices = described_class.prices(%w[a b c], { "a" => 1.0, "b" => 9.0 }, sizes)

      expect(prices).to eq("a" => 1.0, "b" => 9.0, "c" => 5.0)
    end

    it "falls back to size when there is no table" do
      expect(described_class.prices(%w[a bbb], {}, sizes)).to eq("a" => 1.0, "bbb" => 3.0)
    end
  end

  describe ".partition" do
    let(:table) { skewed_table }

    def groups(prices = table) = described_class.partition(files, 4, prices)

    it "holds every file exactly once", :aggregate_failures do
      expect(groups.flatten).to match_array(files)
      expect(groups.flatten.size).to eq(files.size)
    end

    it "gives the same partition for the same input", :aggregate_failures do
      expect(described_class.partition(files, 4, table)).to eq(groups)
      expect(described_class.partition(files.reverse, 4, table)).to eq(groups)
    end

    it "balances by seconds: the slowest file stands alone" do
      expect(groups).to include([files.first])
    end

    it "beats a split that prices every file alike, when one file takes most of the time" do
      by_size = described_class.partition(files, 4, files.to_h { |file| [file, 1.0] })
      by_seconds = groups

      expect(by_seconds.map { |group| load_of(group, table) }.max).to be < by_size.map { |group| load_of(group, table) }.max
    end

    it "leaves a group empty rather than fail when there are more shards than files" do
      expect(described_class.partition(%w[a], 3, { "a" => 1.0 }).map(&:size)).to eq([1, 0, 0])
    end
  end
end
