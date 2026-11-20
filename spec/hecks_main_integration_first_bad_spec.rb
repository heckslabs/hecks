require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"
require "hecks/hecks/adapters/main_verification"

# The search for the first bad merge: a binary search over landings that reads facts and
# decides nothing, and the line a failed verification gains from it while the shallow check
# is off.
RSpec.describe Hecks::Adapters::MainIntegration::FirstBad do
  let(:merges) { Array.new(8) { |index| { sha: "sha#{index}", subject: "merge #{index}", paths: [] } } }
  let(:probed) { [] }

  def search_for(bad, **options)
    probe = lambda do |merge|
      probed << merge[:sha]
      [!bad.include?(merge[:sha]), ({ spec: "spec/x_spec.rb" } if bad.include?(merge[:sha]))]
    end
    @search = described_class.new(merges, probe: probe, **options)
    @search.call
  end

  alias_method :search, :search_for

  it "keeps a log of each probe: the merge and whether it was green or red" do
    search(%w[sha5 sha6 sha7])
    expect(@search.log).to eq(["sha3 green", "sha5 red", "sha5 red", "sha4 green"])
  end

  it "names the first merge that fails among good ones", :aggregate_failures do
    found = search(%w[sha5 sha6 sha7])
    expect(found[:sha]).to eq("sha5")
    expect(found[:finding]).to eq(spec: "spec/x_spec.rb")
  end

  it "probes no more than a binary search needs" do
    search(%w[sha5 sha6 sha7])
    expect(probed.size).to be <= 6
  end

  it "probes a failing merge a second time before blaming it" do
    search(%w[sha5 sha6 sha7])
    expect(probed.count("sha5")).to eq(2)
  end

  it "does not blame a merge whose second probe passes", :aggregate_failures do
    seen = Hash.new(0)
    probe = ->(merge) { [merge[:sha] != "sha3" || (seen[:three] += 1) > 1, { spec: "spec/x_spec.rb" }] }
    search = described_class.new(merges, probe: probe)
    expect(search.call).to be_nil
    expect(search.flaky).to eq(["sha3"])
  end

  it "answers nil when no merge fails" do
    expect(search([])).to be_nil
  end

  it "answers the first failing merge when a later one mends it" do
    expect(search(%w[sha1 sha2 sha3])[:sha]).to eq("sha1")
  end

  it "says why when no merge fails" do
    search_for([])
    expect(@search.reason).to eq("no merge in the range turns the failing specs red")
  end

  it "answers nil, saying the budget was spent, when it is" do
    search_for(%w[sha7], limit: 1)
    expect(@search.reason).to include("probe budget of 1 spent")
  end

  it "answers nil, saying why, when a probe raises", :aggregate_failures do
    search = described_class.new(merges, probe: ->(_) { raise "boom" })
    expect(search.call).to be_nil
    expect(search.reason).to eq("the search stopped: boom")
  end
end
