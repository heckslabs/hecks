require "hecks/local_layer/adapters/batch_applier"
require "json"
require "tmpdir"

# An applied batch replaces its target, and only with the diff that was shown.
RSpec.describe Hecks::Adapters::BatchApplier do
  subject(:applier) { described_class.new(settings: { path: journal, root: dir }) }

  let(:dir)     { Dir.mktmpdir }
  let(:target)  { { value: "triage.bluebook" } }
  let(:journal) { File.join(dir, "edits.journal") }
  let(:run)     { { value: "sprint-9" } }
  let(:source)  { "Hecks.bluebook \"Triage\" do\n  aggregate \"Incident\" do\n    attribute :name, String\n  end\nend\n" }

  before do
    File.write(File.join(dir, "triage.bluebook"), source)
    File.write(journal, "#{JSON.generate({ run: { value: "e1" }, target: { value: "triage.bluebook" }, batch: run,
                                           operation: { value: "AddAttribute" }, subject: { value: "Incident" },
                                           detail: { value: "attribute :age, String" }, status: "batched" })}\n")
  end

  after { FileUtils.remove_entry(dir) }

  def shown = Hecks::Adapters::BatchPreviewer.new(settings: { path: journal, root: dir }).diff(run: run, target: target)[:diff]

  it "writes the patched target when the diff is the one shown" do
    applier.write(run: run, target: target, diff: shown)
    expect(File.read(File.join(dir, "triage.bluebook"))).to include("attribute :age, String")
  end

  it "leaves the target byte-identical when the diff is not the one shown", :aggregate_failures do
    expect { applier.write(run: run, target: target, diff: { value: "ee99" }) }.to raise_error(described_class::Refused)
    expect(File.read(File.join(dir, "triage.bluebook"))).to eq(source)
  end

  it "leaves no temp file behind" do
    applier.write(run: run, target: target, diff: shown)
    expect(Dir.children(dir).grep(/\.tmp/)).to be_empty
  end

  it "refuses a target that cannot be read" do
    expect { applier.write(run: run, target: { value: "gone.bluebook" }, diff: shown) }
      .to raise_error(described_class::Refused, /cannot be read/)
  end
end
