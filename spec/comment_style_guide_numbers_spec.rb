require "spec_helper"
require "hecks/tools"
require "hecks/tools/comment_style"

# The style guides state the linter's thresholds in prose. The thresholds are constants of
# `Hecks::Tools::CommentStyle`, which both linters read, so a number in a guide that no longer
# matches its constant is a guide that tells people the wrong rule. This holds each number the guides
# state to the constant that enforces it.
RSpec.describe "the comment style guides' thresholds" do
  let(:ruby_guide) { File.read(File.join(Hecks::Tools::ROOT, "docs/COMMENT_STYLE_GUIDE.md")) }
  let(:rust_guide) { File.read(File.join(Hecks::Tools::ROOT, "docs/COMMENT_STYLE_GUIDE_RUST.md")) }
  let(:style) { Hecks::Tools::CommentStyle }

  # Every number the text states with this pattern's capture.
  def stated(text, pattern) = text.scan(pattern).flatten.map(&:to_i)

  it "state the line length the linters enforce, in the continuation rule and the section title" do
    [ruby_guide, rust_guide].each do |guide|
      numbers = stated(guide, /would pass (\d+) characters/) + stated(guide, /stay under (\d+) characters/)

      expect(numbers).to eq([style::MAX_LINE, style::MAX_LINE])
    end
  end

  it "state the class doc length past which headers break a comment up" do
    expect(stated(ruby_guide, /longer than about (\d+) lines/)).to eq([style::LONG_CLASS_DOC])
  end

  it "state the comment block cap the linter enforces" do
    expect(stated(ruby_guide, /more than (\d+) consecutive comment lines/)).to eq([style::MAX_BLOCK])
  end

  it "call no threshold provisional while the linter enforces it" do
    expect(ruby_guide).not_to include("is provisional")
  end
end
