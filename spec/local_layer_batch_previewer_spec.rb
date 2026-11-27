require "hecks/local_layer/adapters/batch_previewer"
require "json"
require "tmpdir"

# A batch's gathered edits are shown as a diff, and held to that diff by the checks.
RSpec.describe Hecks::Adapters::BatchPreviewer do
  subject(:previewer) { described_class.new(settings: { path: journal, root: dir }) }

  let(:dir)     { Dir.mktmpdir }
  let(:target)  { File.join(dir, "triage.bluebook") }
  let(:journal) { File.join(dir, "edits.journal") }
  let(:run)     { { value: "sprint-9" } }
  let(:source) do
    <<~RUBY
      Hecks.bluebook "Triage" do
        aggregate "Incident" do
          attribute :name, Name
          identified_by :name
          value_object "Name" do
            attribute :value, String, matches: :present
          end
          lifecycle :status, default: "open" do
            transition "Close" => "closed", from: "open"
          end
          command "Close" do
            reference_to Incident
            attribute :name, Name
          end
        end
      end
    RUBY
  end

  after { FileUtils.remove_entry(dir) }

  def journal!(**held)
    File.open(journal, "a") do |file|
      file.puts(JSON.generate({ target: { value: target }, batch: run, status: "batched" }.merge(held)))
    end
  end

  before do
    File.write(target, source)
    journal!(run: { value: "e1" }, operation: { value: "AddMark" }, subject: { value: "Incident.status" },
             detail: { value: "mark :terminal, \"closed\"" })
  end

  it "answers the digest of the diff the gathered edits make" do
    answer = previewer.diff(run: run, target: { value: target })
    expect(answer[:diff][:value]).to match(/\A[0-9a-f]{12}\z/)
  end

  it "keeps the diff text beside the journal" do
    previewer.diff(run: run, target: { value: target })
    expect(File.read("#{journal}.diffs/sprint-9.diff")).to include("+      mark :terminal, \"closed\"")
  end

  it "leaves the target as it was" do
    previewer.diff(run: run, target: { value: target })
    expect(File.read(target)).to eq(source)
  end

  it "ignores an edit that was withdrawn" do
    journal!(run: { value: "e1" }, operation: { value: "AddMark" }, subject: { value: "Incident.status" },
             detail: { value: "x" }, status: "withdrawn")
    previewer.diff(run: run, target: { value: target })
    expect(File.read("#{journal}.diffs/sprint-9.diff")).not_to include("terminal")
  end

  it "refuses a target that cannot be read" do
    expect { previewer.diff(run: run, target: { value: "#{dir}/gone.bluebook" }) }
      .to raise_error(described_class::Refused, /cannot be read/)
  end

  it "refuses an edit that names no aggregate of the target" do
    journal!(run: { value: "e2" }, operation: { value: "AddMark" }, subject: { value: "Ghost.status" }, detail: { value: "x" })
    expect { previewer.diff(run: run, target: { value: target }) }.to raise_error(described_class::Refused, /Ghost/)
  end

  it "refuses checks against a diff other than the one shown" do
    expect { previewer.check(run: run, target: { value: target }, diff: { value: "ee99" }) }
      .to raise_error(described_class::Refused, /not the one shown/)
  end

  it "passes the checks when the patched target loads and the diff is the one shown" do
    shown = previewer.diff(run: run, target: { value: target })[:diff]
    expect(previewer.check(run: run, target: { value: target }, diff: shown)[:outcome]).to eq(value: "passed")
  end

  it "refuses checks when an edit leaves the target unloadable" do
    journal!(run: { value: "e2" }, operation: { value: "AddAttribute" }, subject: { value: "Incident" },
             detail: { value: "attribute :broken, Nothing" })
    shown = previewer.diff(run: run, target: { value: target })[:diff]
    expect { previewer.check(run: run, target: { value: target }, diff: shown) }
      .to raise_error(described_class::Refused, /does not load/)
  end
end
