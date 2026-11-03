require "hecks"
require "hecks/ports/persistence/plugins/era"
require "tmpdir"
require "fileutils"

# Composing a chain of translation edges into the one edge that leads straight from the held shape
# to the current one. The edges live in a disposable directory; nothing touches a database.
RSpec.describe "Hecks::Translation::Compose" do
  let(:dir) { Dir.mktmpdir }
  let(:translations) { File.join(dir, "translations") }

  before { FileUtils.mkdir_p(translations) }

  after { FileUtils.remove_entry(dir) }

  def write_edge(name, from:, to:, body: "")
    File.write(File.join(translations, name),
               "Hecks.data_translation \"Hecks\", from: \"#{from}\", to: \"#{to}\" do\n#{body}end\n")
  end

  def loaded
    registry = Hecks::Runtime::Registry.new(root: dir)
    Hecks.with_registry(registry) { Dir[File.join(translations, "*.bluebook")].each { |f| Kernel.load(f) } }
    registry.translations
  end

  def chain(from, to) = Hecks::Translation::Compose.chain(loaded, domain: "Hecks", from: from, to: to)

  def composed(from, to)
    Hecks::Translation::Compose.compose(domain: "Hecks", from: from, to: to, chain: chain(from, to))
  end

  it "composes a chain of empty edges into one empty edge" do
    write_edge("2-b.bluebook", from: "a", to: "b")
    write_edge("2-c.bluebook", from: "b", to: "c")
    expect(composed("a", "c").aggregates).to be_empty
  end

  it "renders the composed empty edge as an empty block" do
    write_edge("2-b.bluebook", from: "a", to: "b")
    write_edge("2-c.bluebook", from: "b", to: "c")
    text = Hecks::Translation::ComposeRender.render(composed("a", "c"))
    expect(text).to eq("Hecks.data_translation \"Hecks\", from: \"a\", to: \"c\" do\nend\n")
  end

  it "composes a rename into the composed edge" do
    write_edge("2-b.bluebook", from: "a", to: "b", body: "  aggregate \"Pod\" do\n    rename :old, to: :new\n  end\n")
    write_edge("2-c.bluebook", from: "b", to: "c")
    expect(composed("a", "c").for_aggregate("Pod").renames).to eq(old: :new)
  end

  it "keeps the rename's text when the composed edge is rendered" do
    write_edge("2-b.bluebook", from: "a", to: "b", body: "  aggregate \"Pod\" do\n    rename :old, to: :new\n  end\n")
    write_edge("2-c.bluebook", from: "b", to: "c")
    expect(Hecks::Translation::ComposeRender.render(composed("a", "c"))).to include("rename :old, to: :new")
  end

  it "refuses a broken chain, naming the shape it stops at" do
    write_edge("2-b.bluebook", from: "a", to: "b")
    write_edge("2-d.bluebook", from: "c", to: "d")
    expect { chain("a", "d") }.to raise_error(Hecks::Runtime::WiringError, /chain is broken at b/)
  end

  it "names the intermediate edges the composed one replaces" do
    write_edge("2-b.bluebook", from: "a", to: "b")
    write_edge("2-c.bluebook", from: "b", to: "c")
    write_edge("2-d.bluebook", from: "c", to: "d")
    stale = Hecks::Translation::EdgeFiles.stale(dir, domain: "Hecks", chain: chain("a", "d"))
    expect(stale.map { |path| File.basename(path) }).to contain_exactly("2-b.bluebook", "2-c.bluebook")
  end

  it "keeps the edge that leads to the current shape" do
    write_edge("2-b.bluebook", from: "a", to: "b")
    write_edge("2-d.bluebook", from: "c", to: "d")
    write_edge("2-c.bluebook", from: "b", to: "c")
    stale = Hecks::Translation::EdgeFiles.stale(dir, domain: "Hecks", chain: chain("a", "d"))
    expect(stale).not_to include(File.join(translations, "2-d.bluebook"))
  end
end
