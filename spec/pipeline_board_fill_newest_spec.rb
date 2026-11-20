# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_stages"

# The board's fill reading is the report whose stated time is the latest. A store answers its
# `Roll` records in the order of their keys, so the record it answers last can be days old. The
# recorded roll is the first lines of one a rolling fill recorded on 2026-11-20.
RSpec.describe Hecks::Adapters::PipelineFill do
  let(:today) { File.read(File.expand_path("fixtures/pipeline_board/roll_2026_11_20.txt", __dir__)) }
  let(:days_old) do
    "load 7.6 (limit 16.0, 12 cpus); started 6 of cap 5; headroom 19 of cap 5 (0.4 load per session); " \
      "this fill would start 0; frozen: none; at 2026-11-16T08:06:00Z\nalpha skipped: cap 5 reached"
  end
  let(:admission) do
    "load 3.0 (limit 8.0, 12 cpus); started 4; admission by headroom 9000 MB (ok; ramp 2 per 60s); " \
      "headroom 2 of cap 6 (1.6 load per session); this fill would start 0; frozen: none"
  end
  let(:now) { Time.utc(2026, 11, 20, 18, 49, 54) }

  # A reader over a store that answers the reports in the order given.
  def reader(*reports)
    records = reports.map { |report| { report: report } }
    store = instance_double(Hecks::Adapters::PipelineBoard::RegistryStore, records: records)
    described_class.new(store: store, settings: { now: -> { now } })
  end

  it "reads the roll recorded today, though an older report is the last the store answers", :aggregate_failures do
    fill = reader("", today, days_old).preview

    expect(fill).to include(at: "2026-11-20T18:33:54Z", cap: 7, started: 3, headroom: 13, load: 8.0)
    expect(fill[:skipped].first).to include(slug: "the-beat-is-cleared-from-the-train-copy")
  end

  it "takes the later in the store's order of two reports that state one time" do
    twin = today.sub("started 3 of cap 7", "started 4 of cap 7")
    expect(reader(today, twin).preview[:started]).to eq(4)
  end

  it "ranks a report that states no time below one that does" do
    untimed = days_old.sub("; at 2026-11-16T08:06:00Z", "")
    expect(reader(days_old, untimed).preview[:at]).to eq("2026-11-16T08:06:00Z")
  end

  it "says the report's age in whole minutes, and none for a report that states no time", :aggregate_failures do
    expect(reader(today).preview[:age_minutes]).to eq(16)
    expect(reader(admission).preview[:age_minutes]).to be_nil
  end

  it "reads the admission form of the header, its cap from the headroom clause", :aggregate_failures do
    expect(reader(admission).preview).to include(started: 4, cap: 6, headroom: 2, at: nil)
    expect(reader(admission, days_old.sub("11-16", "11-10")).preview[:cap]).to eq(5)
  end

  it "reads an admission-form report that states its time over an older one" do
    timed = "#{admission}; at 2026-11-20T18:40:00Z"
    expect(reader(timed, days_old).preview).to include(started: 4, cap: 6, age_minutes: 9)
  end
end
