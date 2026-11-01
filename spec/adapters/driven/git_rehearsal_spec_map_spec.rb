require "spec_helper"
require "fileutils"
require "tmpdir"
require "hecks/hecks/adapters/git_rehearsal"

# The map from a push's changed files to the specs that exercise them, over a temporary tree.
RSpec.describe Hecks::Adapters::GitRehearsal::SpecMap do
  let(:root) { Dir.mktmpdir("hecks-spec-map") }
  let(:files) do
    {
      "lib/hecks/widgets/gear_box.rb"                   => nested("Hecks", "Widgets", "GearBox"),
      "lib/hecks/language/bluebook/vocabulary.bluebook" => %(Hecks.bluebook "Vocabulary" do\nend\n),
      "lib/hecks/shop/shop.bluebook"                    => %(Hecks.bluebook "Shop" do\nend\n),
      "spec/gear_box_spec.rb"                           => "# named for the file\n",
      "spec/requires_spec.rb"                           => %(require "hecks/widgets/gear_box"\n),
      "spec/relative_spec.rb"                           => %(require_relative "../lib/hecks/widgets/gear_box"\n),
      "spec/constant_spec.rb"                           => "RSpec.describe Hecks::Widgets::GearBox do\nend\n",
      "spec/unrelated_spec.rb"                          => "# nothing here\n"
    }
  end
  let(:map) { described_class.new(root) }

  def nested(*names)
    names.each_with_index.map { |name, depth| "#{"  " * depth}#{depth == names.size - 1 ? "class" : "module"} #{name}\n" }.join
  end

  before do
    files.each do |path, text|
      FileUtils.mkdir_p(File.dirname(File.join(root, path)))
      File.write(File.join(root, path), text)
    end
  end

  after { FileUtils.remove_entry(root) }

  def specs(*changed, limit: 60, skip: ->(_spec) {}) = map.map(changed, limit: limit, skip: skip).specs

  def add(path, text = "# #{path}\n")
    FileUtils.mkdir_p(File.dirname(File.join(root, path)))
    File.write(File.join(root, path), text)
  end

  it "runs a changed spec itself" do
    expect(specs("spec/unrelated_spec.rb")).to eq(["spec/unrelated_spec.rb"])
  end

  it "runs the spec named for a changed Ruby file first" do
    expect(specs("lib/hecks/widgets/gear_box.rb").first).to eq("spec/gear_box_spec.rb")
  end

  it "runs the specs that require a changed Ruby file by either spelling" do
    expect(specs("lib/hecks/widgets/gear_box.rb")).to include("spec/requires_spec.rb", "spec/relative_spec.rb")
  end

  it "runs the specs that name its constant" do
    expect(specs("lib/hecks/widgets/gear_box.rb")).to include("spec/constant_spec.rb")
  end

  it "leaves out a spec that has nothing to do with the file" do
    expect(specs("lib/hecks/widgets/gear_box.rb")).not_to include("spec/unrelated_spec.rb")
  end

  it "runs the specs that mention a bluebook's domain name or path" do
    add("spec/shop_spec.rb", %(Hecks.load("Shop")\n))
    add("spec/path_spec.rb", %(File.read("lib/hecks/shop/shop.bluebook")\n))
    expect(specs("lib/hecks/shop/shop.bluebook")).to contain_exactly("spec/shop_spec.rb", "spec/path_spec.rb")
  end

  it "runs the specs that mention a world's declared name" do
    add("lib/hecks/shop/shop.world", %(Hecks.world "Shop" do\nend\n))
    add("spec/shop_spec.rb", %(Hecks.load("Shop")\n))
    expect(specs("lib/hecks/shop/shop.world")).to eq(["spec/shop_spec.rb"])
  end

  context "with the language's own bluebooks" do
    before { %w[shape_ledger_spec conformance_run_spec semantics_corpus_spec].each { |name| add("spec/#{name}.rb") } }

    it "adds the ledger, conformance and corpus specs" do
      expect(specs("lib/hecks/language/bluebook/vocabulary.bluebook"))
        .to include("spec/shape_ledger_spec.rb", "spec/conformance_run_spec.rb", "spec/semantics_corpus_spec.rb")
    end

    it "leaves them to an ordinary bluebook" do
      expect(specs("lib/hecks/shop/shop.bluebook")).not_to include("spec/shape_ledger_spec.rb")
    end
  end

  it "runs only the Ruby specs that drive a changed Rust file" do
    %w[rust_parity_spec semantics_corpus_spec docs_links_spec].each { |name| add("spec/#{name}.rb") }
    expect(specs("rust/src/lib.rs")).to contain_exactly("spec/rust_parity_spec.rb", "spec/semantics_corpus_spec.rb")
  end

  it "runs the docs specs for a changed docs file" do
    docs = %w[docs_links_spec reference_index_spec changelog_shape_spec adr_rows_spec]
    (docs + ["rust_parity_spec"]).each { |name| add("spec/#{name}.rb") }
    expect(specs("docs/guide.md")).to match_array(docs.map { |name| "spec/#{name}.rb" })
  end

  context "when the limit is below what maps" do
    let(:mapping) { map.map(["lib/hecks/widgets/gear_box.rb"], limit: 2) }

    it "keeps the closest specs" do
      expect(mapping.specs.first).to eq("spec/gear_box_spec.rb")
    end

    it "says how many ran and that the rest run in CI" do
      expect(mapping.cap_note).to eq("capped at 2 of 4; the rest run in CI")
    end
  end

  it "says nothing about a cap when everything runs" do
    expect(map.map(["lib/hecks/widgets/gear_box.rb"], limit: 60).cap_note).to eq("")
  end

  it "leaves out a spec the skip says cannot run, and says why" do
    skip = ->(spec) { "needs cargo" if spec == "spec/requires_spec.rb" }
    mapping = map.map(["lib/hecks/widgets/gear_box.rb"], limit: 60, skip: skip)
    expect(mapping.skipped).to eq("spec/requires_spec.rb" => "needs cargo")
  end
end
