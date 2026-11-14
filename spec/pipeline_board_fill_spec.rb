require "spec_helper"
require_relative "support/pipeline_board_world"
require_relative "support/no_child_process"

# The board's fill tile reads the report the last rolling fill recorded, in this process. With no
# report it says so: it never asks a launcher, which would be load added on a timer.
RSpec.describe Hecks::Adapters::PipelineFill do
  include NoChildProcess

  let(:report) do
    ["load 3.0 (limit 8.0, 12 cpus); started 4 of cap 6; this fill would start 1; frozen: none; at 2026-11-09T07:00:00Z",
     "would start alpha: Outcome: alpha",
     "beta skipped: cap 6 reached"].join("\n")
  end
  let(:unavailable) { Hecks::Adapters::PipelineBoard::Unavailable }

  def reader(recorded) = described_class.new(settings: { report: -> { recorded } })

  it "parses the recorded report", :aggregate_failures do
    fill = reader(report).preview

    expect(fill).to include(load: 3.0, limit: 8.0, cap: 6, started: 4, at: "2026-11-09T07:00:00Z")
    expect(fill[:would_start]).to eq([{ slug: "alpha", title: "Outcome: alpha" }])
    expect(fill[:skipped]).to eq([{ slug: "beta", reason: "cap 6 reached" }])
  end

  it "shows a report that states no time, with no time" do
    expect(reader(report.sub("; at 2026-11-09T07:00:00Z", "")).preview[:at]).to be_nil
  end

  it "says no fill is recorded while the store holds no report" do
    expect { reader(nil).preview }.to raise_error(unavailable, described_class::NONE_RECORDED)
  end

  def asked(fill)
    fill.preview
  rescue unavailable => e
    e.message
  end

  it "starts no process while no report is recorded" do
    expect(children_started { asked(described_class.new(registry: nil)) }).to be_empty
  end

  it "starts no process when the store cannot be read", :aggregate_failures do
    store = instance_double(Hecks::Adapters::PipelineBoard::RegistryStore)
    allow(store).to receive(:records).and_raise(unavailable, "still opening")
    fill = described_class.new(store: store)
    expect(children_started { asked(fill) }).to be_empty
    expect(asked(fill)).to eq(described_class::NONE_RECORDED)
  end

  it "reads a confirmed report: the items it started, and the ones that went back", :aggregate_failures do
    confirmed = [report.lines.first.strip, "started alpha", "started beta (then refused: busy)",
                 "yielded gamma: cap"].join("\n")
    fill = reader(confirmed).preview
    expect(fill[:launched]).to eq([{ slug: "alpha" }, { slug: "beta" }])
    expect(fill[:skipped]).to eq([{ slug: "gamma", reason: "cap" }])
  end

  it "reads the newest Roll report the store holds, the live store's when it is named" do
    store = instance_double(Hecks::Adapters::PipelineBoard::RegistryStore, records: [{ report: report }, { report: "x" }])
    fill = described_class.new(store: store)
    expect(fill.preview[:would_start]).to eq([{ slug: "alpha", title: "Outcome: alpha" }])
  end

  it "refuses a report it cannot read" do
    expect { reader("not a fill report").preview }.to raise_error(unavailable, "unreadable fill report")
  end
end
