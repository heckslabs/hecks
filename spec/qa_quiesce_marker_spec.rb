require "spec_helper"
require "tmpdir"
require "hecks/quality_control/adapters/qa_quiesce_marker"
require "hecks/hecks/adapters/qa_quiescing"

# The QA quiet marker and the `Quiescing` adapter over it, on a temp path: no tick, no ledger.
RSpec.describe Hecks::Adapters::QaQuiesceMarker, :aggregate_failures do
  let(:dir) { Dir.mktmpdir("qa_quiesce") }
  let(:path) { File.join(dir, "quiesce") }
  let(:now) { [Time.utc(2026, 11, 1, 12, 0, 0)] }
  # rubocop:disable-next RSpec/DescribedClass
  let(:marker) { Hecks::Adapters::QaQuiesceMarker.new(path: path, stale_after: 7200, clock: -> { now.first }) }

  after { FileUtils.remove_entry(dir) }

  it "holds with an owner, reason and time, and reports them with the age" do
    marker.hold!(owner: "mint-agent", reason: "rehearsal to mint")
    now[0] += 600

    expect(JSON.parse(File.read(path))).to include("owner" => "mint-agent", "reason" => "rehearsal to mint")
    expect(marker.status).to include("quiesced:", "owner mint-agent", "rehearsal to mint", "held 10m ago")
    expect(marker.active.owner).to eq("mint-agent")
  end

  it "reports no marker when none is held" do
    expect(marker.status).to start_with("not quiesced")
    expect(marker.active).to be_nil
  end

  it "ignores a stale marker and reports it as stale" do
    marker.hold!(owner: "crashed", reason: "mint")
    now[0] += 7201

    expect(marker.active).to be_nil
    expect(marker.stale.owner).to eq("crashed")
    expect(marker.status).to start_with("stale (ignored)")
  end

  it "refuses a release by another owner without force, and allows it with force" do
    marker.hold!(owner: "a", reason: "r")

    expect { marker.release!(owner: "b") }.to raise_error(Hecks::Adapters::QaQuiesceMarker::Refused, /held by a/)
    expect(File.exist?(path)).to be(true)
    marker.release!(owner: "b", force: true)
    expect(File.exist?(path)).to be(false)
  end

  it "lets the owner release, and a release with nothing held is a no-op" do
    marker.hold!(owner: "a", reason: "r")

    expect(marker.release!(owner: "a").owner).to eq("a")
    expect(marker.release!(owner: "a")).to be_nil
  end

  it "refuses a hold over another owner's fresh marker, but replaces a stale one" do
    marker.hold!(owner: "a", reason: "r")
    expect { marker.hold!(owner: "b", reason: "r") }.to raise_error(Hecks::Adapters::QaQuiesceMarker::Refused)

    now[0] += 7201
    expect(marker.hold!(owner: "b", reason: "r2").owner).to eq("b")
  end

  it "treats an unreadable marker as held, owned by unknown" do
    File.write(path, "not json")

    expect(marker.active.owner).to eq("unknown")
  end

  describe Hecks::Adapters::QaQuiescing do
    let(:adapter) { described_class.new(settings: { marker: marker }) }

    it "marks, reports and clears through the port's methods" do
      expect(adapter.mark(owner: { value: "a" }, reason: { value: "why" })[:output][:value]).to include("quiesced:")
      expect(adapter.status[:text]).to include("owner a", "why")
      expect { adapter.clear(owner: { value: "b" }) }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure)
      expect(adapter.clear(owner: { value: "b" }, force: { value: true })[:output][:value]).to start_with("released:")
    end
  end
end
