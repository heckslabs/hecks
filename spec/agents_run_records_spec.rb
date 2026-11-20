require "spec_helper"
require "hecks/agents/adapters/run_records"

# How a cited run ended, read from a stand-in for its kept record: the adapter answers the record's
# facts and refuses a run it cannot read back.
RSpec.describe Hecks::Adapters::RunRecords do
  def reader(record) = described_class.new(records: ->(_kind, _key) { record })

  def read(record, kind = "behaviors")
    reader(record).read(kind: { value: kind }, run: { value: "abc1-behaviors" }).transform_values { |field| field[:value] }
  end

  let(:report) { "agents.behaviors\n  ok    Judge refuses\n  FAIL  Judge records\n        why\n" }

  it "answers a behaviors run's domain, status and the scenarios its report ran" do
    record = { run: "abc1-behaviors", subject: "lib/hecks/agents", status: "failed", refusal: report }
    expect(read(record)).to include(subject: "lib/hecks/agents", status: "failed", scenarios: 2)
  end

  it "answers a model check's domains, status and count" do
    record = { run: "abc1-behaviors", domains: "lib/hecks/agents", status: "clean", checked: "1" }
    expect(read(record, "model_check")).to include(subject: "lib/hecks/agents", status: "clean", scenarios: 1)
  end

  it "refuses a run no record keeps" do
    expect { read(nil) }.to raise_error(described_class::Unkept, /no behaviors run is kept under abc1-behaviors/)
  end

  it "refuses a run that has not ended" do
    expect { read({ run: "abc1-behaviors", status: "requested" }) }.to raise_error(described_class::Unkept, /has not ended/)
  end

  it "refuses a boot that holds no Hecks store" do
    expect { described_class.new.read(kind: "behaviors", run: "abc1-x") }
      .to raise_error(described_class::Unkept, /Hecks domain is not booted/)
  end
end
