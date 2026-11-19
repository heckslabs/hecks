require "tmpdir"
require "fileutils"
require "hecks/tools/comment_style"

# The comment linter's per-file cache: a file whose text was seen before is not parsed again,
# and the report is the same as a run that parses every file.
RSpec.describe "Hecks::Tools::CommentStyle::FileCache" do
  let(:style) { Hecks::Tools::CommentStyle }
  let(:root)  { Dir.mktmpdir("comment-cache") }
  let(:tree)  { File.join(root, "tree") }
  let(:store) { File.join(root, "cache") }

  before do
    FileUtils.mkdir_p(tree)
    File.write(File.join(tree, "a.rb"), "# #{"x" * 120}\nx = 1\n")
    File.write(File.join(tree, "b.rb"), "#{long_block}\n\nclass Storehouse\n  LIMIT = 1\nend\n")
  end

  def long_block = Array.new(30) { |i| "# line #{i}" }.join("\n")

  after { FileUtils.rm_rf(root) }

  def cache(digest = "linter") = style::FileCache.new(store, digest: digest)

  def found(cache: self.cache, baseline: {}, only: nil)
    style::Run.new([tree], cache: cache, baseline: baseline, only: only).violations.map(&:to_a)
  end

  def parses
    allow(style::SourceFile).to receive(:new).and_call_original
    yield
    style::SourceFile
  end

  def change_b = File.write(File.join(tree, "b.rb"), "class Storehouse\n  LIMIT = 2\nend\n")

  it "parses only the changed file of a warm tree" do
    found
    change_b
    expect(parses { found }).to have_received(:new).once
  end

  it "reports what a run that parses every file reports", :aggregate_failures do
    found
    change_b
    expect(found).to eq(found(cache: style::FileCache::None))
    expect(found.map(&:first)).to include(File.join(tree, "a.rb"))
  end

  it "reports, from the cache, the long block and the undocumented type of a file" do
    found
    expect(found.map { |v| v[2] }).to contain_exactly("long_line", "long_block", "undocumented_class")
  end

  it "judges cached blocks against the baseline it is given, without parsing", :aggregate_failures do
    found
    held = { File.join(tree, "b.rb") => { "line 0" => 30 } }
    expect(parses { found(baseline: held) }).not_to have_received(:new)
    expect(found(baseline: held).map { |v| v[2] }).not_to include("long_block")
  end

  it "fills, in a long-block run, the entries a full run reuses" do
    found(only: ["long_block"])
    expect(parses { found }).to have_received(:new).exactly(0).times
  end

  it "reads nothing kept under another linter's digest, and removes it", :aggregate_failures do
    found
    expect(parses { found(cache: cache("changed")) }).to have_received(:new).twice
    expect(Dir.children(store)).to eq(["changed.json"])
  end

  it "keeps no cache in a spec, or when it is turned off", :aggregate_failures do
    expect(style::FileCache.default({ "HECKS_WRITES_LOCAL" => "1" })).to be(style::FileCache::None)
    expect(style::FileCache.default({ "HECKS_COMMENT_CACHE" => "off" })).to be(style::FileCache::None)
  end

  it "keeps no cache for a run given none" do
    allow(style::FileCache).to receive(:new)
    style::Run.new([tree]).violations
    expect(style::FileCache).not_to have_received(:new)
  end
end
