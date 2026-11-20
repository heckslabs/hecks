require "spec_helper"
require "hecks/doc/sources"

# Each Region source names a region that differs from what its generator renders, never checks
# prose, and runs a doctested region through the doctest it is given.
RSpec.describe Hecks::Doc::Sources do
  let(:root) { InMemoryDomain::ROOT }

  # Sources whose committed page at `path` reads with `from` replaced by `to`.
  def editing(path, from, to)
    committed = lambda do |asked|
      text = File.read(File.join(root, asked))
      asked == path ? text.sub(from, to) : text
    end
    described_class.new(root, committed: committed)
  end

  def region(source, kind: "projected") = { anchor: source, kind: kind, source: source, assertion: "" }

  it "names a README region that differs from what it renders" do
    sources = editing("README.md", "<!-- generated:begin id=corpus -->\n", "\\0- stale\n")
    expect(sources.drift("README.md", region("readme:corpus"))).to start_with("README.md#readme:corpus: differs")
  end

  it "names a tools section that differs from its RetiredScript rows" do
    sources = editing("docs/tools.md", "|---|---|\n", "\\0| stale | row |\n")
    expect(sources.drift("docs/tools.md", region("tools:Custodian"))).to include("project_tools_doc!")
  end

  it "names a CLI guide section that still lists a renamed command" do
    # dead-name-check: skip
    sources = editing("docs/implemented/guides/cli/migrate.md", "`hecks SchemaRevision.compact!", "`hecks Era.compact!")
    expect(sources.drift("docs/implemented/guides/cli/migrate.md", region("cli:migrate")))
      .to include("project_tools_doc!")
  end

  it "never checks a prose region" do
    expect(described_class.new(root).drift("README.md", region("", kind: "prose"))).to be_nil
  end

  it "runs a doctested region through the doctest it is given" do
    sources = described_class.new(root, doctest: ->(_path) { false })
    expect(sources.drift("README.md", region("doctest:README.md", kind: "doctested")))
      .to start_with("README.md#doctest:README.md: its examples")
  end
end
