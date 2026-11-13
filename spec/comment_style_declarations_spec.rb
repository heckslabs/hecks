require "spec_helper"
require "tmpdir"
require "hecks/tools/comment_style"

# The comment check over a declaration file: a run of comment lines past the declaration cap is a
# long block, held by the baseline when it was already there.
RSpec.describe Hecks::Tools::CommentStyle::DeclarationFile do
  def cap = Hecks::Tools::CommentStyle::MAX_DECLARATION_BLOCK

  # A bluebook whose one comment block has the given number of lines.
  def bluebook(lines, first: "What the order is.")
    comment = [first, *Array.new(lines - 1) { |index| "More about it, line #{index + 2}." }].map { |text| "  # #{text}\n" }
    "Hecks.bluebook \"Shop\" do\n#{comment.join}  aggregate \"Order\" do\n  end\nend\n"
  end

  def violations(lines, baseline: {}) = described_class.new("shop.bluebook", bluebook(lines)).violations(baseline: baseline)

  it "passes a block at the cap" do
    expect(violations(cap)).to be_empty
  end

  it "refuses a block one line past the cap, saying where it belongs", :aggregate_failures do
    found = violations(cap + 1).first
    expect(found.category).to eq("long_block")
    expect(found.message).to include("over #{cap} in a declaration file", "say it in the declaration")
  end

  it "names the block's first line, where it starts" do
    expect(violations(cap + 1).first.line).to eq(2)
  end

  it "passes a block the baseline holds at its length" do
    held = { "shop.bluebook" => { "What the order is." => cap + 2 } }
    expect(violations(cap + 2, baseline: held)).to be_empty
  end

  it "refuses a held block that has grown" do
    held = { "shop.bluebook" => { "What the order is." => cap + 1 } }
    expect(violations(cap + 2, baseline: held).first.message).to include("baselined at #{cap + 1}")
  end

  it "counts two short blocks apart, not as one long one" do
    text = "# one\n# two\nattaches \"A\"\n# three\n# four\n# five\nattaches \"B\"\n"
    expect(described_class.new("x.hecksagon", text).long_blocks).to be_empty
  end
end
