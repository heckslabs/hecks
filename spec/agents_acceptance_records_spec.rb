require "spec_helper"
require "hecks/agents/adapters/run_records"

# How one acceptance reference's scenario ended in the behaviors run cited for it, read from a
# stand-in for the run's kept record: only the named scenario's line counts.
RSpec.describe Hecks::Adapters::RunRecords, "#read_acceptance" do
  let(:file) { "lib/hecks/agents/agents.behaviors" }
  let(:report) { "#{file}\n  ok    Judge refuses\n  FAIL  Judge records\n        why\n" }
  let(:kept) { { run: "abc1-acceptance-1", subject: file, status: "failed", refusal: report } }

  def read(scenario, record = kept)
    reader = described_class.new(records: ->(_kind, _key) { record })
    reader.read_acceptance(ref: { value: "#{file}##{scenario}" }, run: { value: "abc1-acceptance-1" })
          .transform_values { |field| field[:value] }
  end

  it "answers passed for a scenario the run passed, though another in the file failed" do
    expect(read("Judge refuses")).to include(ref: "#{file}#Judge refuses", result: "passed")
  end

  it "answers failed for a scenario the run failed" do
    expect(read("Judge records")[:result]).to eq("failed")
  end

  it "answers unresolved for a scenario the run does not hold" do
    expect(read("Judge refuses a clean")[:result]).to eq("unresolved")
  end

  it "refuses a run of another file than the reference's" do
    expect { read("Judge refuses", kept.merge(subject: "lib")) }.to raise_error(described_class::Unkept, /ran lib, not #{file}/)
  end

  it "refuses a run that has not ended" do
    expect { read("Judge refuses", kept.merge(status: "requested")) }.to raise_error(described_class::Unkept, /has not ended/)
  end

  it "refuses a run no record keeps" do
    expect { read("Judge refuses", nil) }.to raise_error(described_class::Unkept, /no behaviors run is kept/)
  end
end
