require "spec_helper"
require "json"
require "hecks/hecks/adapters/machine_sampling"
require_relative "support/process_table_fixtures"

# Each reading of the machine records the CPU it finds, summed by purpose, so a load spike is
# attributed; the per-day figure is read from the stored readings and changes nothing.
RSpec.describe "the machine's top CPU consumers by purpose" do
  include ProcessTableFixtures

  Sampling = Hecks::Adapters::MachineSampling

  def table
    [Entry.new(1, 0, 40.0, "/usr/bin/ruby /x/bin/rspec spec/a_spec.rb"),
     Entry.new(2, 0, 30.0, "/usr/bin/ruby exe/hecks gate_run.gate! stage=quick"),
     Entry.new(3, 0, 20.0, "/usr/bin/ruby exe/hecks Heartbeat.beat!"),
     Entry.new(4, 0, 100.0, "/usr/libexec/fseventsd"),
     Entry.new(5, 0, 12.0, "claude --bg work"), Entry.new(6, 0, 3.0, "/usr/sbin/mds_stores")]
  end

  let(:rows) { Sampling::Consumers.new(table).rows }

  it "sorts each process into the purpose it serves" do
    expect(rows.to_h { |row| [row[:purpose], row[:cpu]] }).to eq(
      "fseventsd" => 100.0, "specs_gates_lint" => 70.0, "hecks_boots_beats" => 20.0,
      "claude_sessions" => 12.0, "other" => 3.0
    )
  end

  it "lists the purposes busiest first, at most five, with the busiest command of each" do
    expect(rows.first).to eq(purpose: "fseventsd", cpu: 100.0, top: "fseventsd")
  end

  it "records the consumers on every reading, as text" do
    adapter = Sampling.new(settings: { readings: -> { {} }, clock: -> { 5.0 }, consumers: -> { rows } })
    expect(JSON.parse(adapter.read[:consumers]).first["purpose"]).to eq("fseventsd")
  end

  it "reads the processes only when no stand-in readings are given" do
    adapter = Sampling.new(settings: { readings: -> { {} }, clock: -> { 5.0 } })
    expect(adapter.read[:consumers]).to be_nil
  end

  it "sums the stored readings' CPU by purpose per day, as the mean percent of one core" do
    held = [{ taken_at: "2026-11-23T10:00:00Z", consumers: JSON.generate(rows) },
            { taken_at: "2026-11-23T10:01:00Z", consumers: JSON.generate([{ purpose: "other", cpu: 7.0 }]) }]
    expect(Sampling::PurposeDays.new(held).rows.find { |row| row[:purpose] == "other" })
      .to eq(day: "2026-11-23", purpose: "other", cpu: 5.0, readings: 2)
  end
end
