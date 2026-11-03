require "spec_helper"
require "tmpdir"
require "fileutils"
require "open3"
require "hecks/hecks/adapters/codebase/impacted_specs"

RSpec.describe Hecks::Adapters::Codebase::ImpactedSpecs do
  let(:failure) { Hecks::Adapters::ConsoleCapture::Failure }
  let(:dir) { Dir.mktmpdir("impacted-specs") }
  let(:tree) { Hecks::Adapters::Codebase::Tree.new(root: dir) }
  let(:impacted) { described_class.new(tree, scratch: -> { false }, files: files) }
  let(:files) { instance_double(Hecks::Adapters::Codebase::SpecFiles, run: "1 example, 0 failures") }

  after { FileUtils.rm_rf(dir) }

  def write(path, text = "")
    FileUtils.mkdir_p(File.dirname(File.join(dir, path)))
    File.write(File.join(dir, path), text)
  end

  def git(*args) = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", "-C", dir, *args)

  def spec_text(about) = "RSpec.describe #{about.inspect} do\n  it(\"works\") { expect(true).to be(true) }\nend\n"

  # A repository whose main branch holds the specs, on a feature branch with nothing changed yet.
  def repository
    write("spec/widget_spec.rb", spec_text("Widget"))
    write("spec/shop_world_spec.rb", spec_text("Shop").sub("RSpec.describe", "# lib/shop.bluebook\nRSpec.describe"))
    write("spec/docs_guides_spec.rb", spec_text("guides"))
    write("spec/fetch_spec.rb", spec_text("fetch").sub("RSpec.describe", "# curl it\nRSpec.describe"))
    git("init", "-b", "main")
    git("add", "-A")
    git("commit", "-m", "base")
    git("checkout", "-b", "feature")
  end

  def dry(**options) = impacted.call(base: "main", dry: true, **options)

  before { repository }

  it "maps a new Ruby file to the spec named for it", :aggregate_failures do
    write("lib/widget.rb", "class Widget; end\n")
    expect(dry).to include("changed since main: 1 file(s)", "  lib/widget.rb", "  spec/widget_spec.rb")
    expect(dry).to include("dry run: no spec run")
  end

  it "maps a bluebook file to the specs that mention it" do
    write("lib/shop.bluebook", "Hecks.bluebook \"Shop\" do\nend\n")
    expect(dry).to include("  spec/shop_world_spec.rb")
  end

  it "maps a docs file to the docs specs" do
    write("docs/guide.md", "# guide\n")
    expect(dry).to include("  spec/docs_guides_spec.rb")
  end

  it "reads a committed change as well as an uncommitted one" do
    write("lib/widget.rb", "class Widget; end\n")
    git("add", "-A")
    git("commit", "-m", "widget")
    expect(dry).to include("  spec/widget_spec.rb")
  end

  it "says so and runs nothing when no spec is touched" do
    write("notes.txt", "hello\n")
    expect(impacted.call(base: "main")).to include("nothing impacted; nothing run")
  end

  it "caps the specs and says how many were left out", :aggregate_failures do
    write("docs/guide.md", "# guide\n")
    write("lib/widget.rb", "class Widget; end\n")
    expect(dry(cap: 1)).to include("capped at 1 of 2; the rest run in CI")
  end

  it "skips a spec that needs the network, and says why" do
    write("lib/fetch.rb", "module Fetch; end\n")
    expect(dry).to include("skipped: spec/fetch_spec.rb (needs network)")
  end

  describe "an :io spec" do
    before do
      write("spec/ledger_spec.rb", "RSpec.describe \"Ledger\", :io do\nend\n")
      write("lib/ledger.rb", "class Ledger; end\n")
    end

    it "is skipped when no scratch Postgres answers" do
      expect(dry).to include("skipped: spec/ledger_spec.rb (no scratch Postgres)")
    end

    context "when a scratch Postgres answers" do
      let(:impacted) { described_class.new(tree, scratch: -> { true }, files: files) }

      it "is run as CI runs it" do
        impacted.call(base: "main")
        expect(files).to have_received(:run).with(hash_including(files: ["spec/ledger_spec.rb"], env: { "CI" => "true" }))
      end
    end
  end

  it "runs the mapped specs in one batch with the isolation asked for", :aggregate_failures do
    write("lib/widget.rb", "class Widget; end\n")
    report = impacted.call(base: "main", isolation: "shared")
    expect(files).to have_received(:run).with(hash_including(files: ["spec/widget_spec.rb"], isolation: "shared"))
    expect(report.lines.last).to eq("1 example, 0 failures")
  end

  it "refuses with the batch's report when a file fails" do
    write("lib/widget.rb", "class Widget; end\n")
    allow(files).to receive(:run).and_raise(failure, "widget failed\n\n1 example, 1 failure")
    expect { impacted.call(base: "main") }.to raise_error(failure, /widget failed.*1 example, 1 failure\z/m)
  end

  # What the rehearsal's own map names for these changed files.
  def rehearsal_map(changed)
    skip = Hecks::Adapters::GitRehearsal::Impacted::Skips.new(dir, scratch: -> { false })
    Hecks::Adapters::GitRehearsal::SpecMap.new(dir).map(changed, limit: 60, skip: skip).specs
  end

  it "maps as the rehearsal's own map does for the same diff" do
    write("lib/widget.rb", "class Widget; end\n")
    write("docs/guide.md", "# guide\n")
    expect(dry.scan(%r{^  (spec/\S+)}).flatten).to eq(rehearsal_map(%w[docs/guide.md lib/widget.rb]))
  end
end
