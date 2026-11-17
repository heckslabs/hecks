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

  def search(bad, **options)
    probe = lambda do |merge|
      probed << merge[:sha]
      [!bad.include?(merge[:sha]), ({ spec: "spec/x_spec.rb" } if bad.include?(merge[:sha]))]
    end
    described_class.new(merges, probe: probe, **options).call
  end

  it "names the first merge that fails among good ones", :aggregate_failures do
    found = search(%w[sha5 sha6 sha7])
    expect(found[:sha]).to eq("sha5")
    expect(found[:finding]).to eq(spec: "spec/x_spec.rb")
  end

  it "probes no more than a binary search needs" do
    search(%w[sha5 sha6 sha7])
    expect(probed.size).to be <= 4
  end

  it "answers nil when no merge fails" do
    expect(search([])).to be_nil
  end

  it "answers the first failing merge when a later one mends it" do
    expect(search(%w[sha1 sha2 sha3])[:sha]).to eq("sha1")
  end

  it "answers nil when the head moved" do
    expect(search(%w[sha5], current: -> { false })).to be_nil
  end

  it "answers nil when the probe budget is spent" do
    expect(search(%w[sha7], limit: 1)).to be_nil
  end

  it "answers nil when a probe raises" do
    expect(described_class.new(merges, probe: ->(_) { raise "boom" }).call).to be_nil
  end
end
