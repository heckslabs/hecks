require "spec_helper"
require "hecks/hecks/adapters/machine_sampling"
require_relative "support/process_table_fixtures"

# `Machine.busiest` reads which process classes use the CPU and whose child they are. It reads a
# stand-in table here; it never stops a process.
RSpec.describe "the busiest process classes" do
  include ProcessTableFixtures

  let(:rows) { process_classes.rows }

  it "puts the runaway class first, counted and summed, with the session whose shell owns it" do
    expect(rows.first).to eq(name: "yes", count: 24, cpu: 1032.0, session: "s1")
  end

  it "names no session for a process no claimed host is above" do
    expect(rows.find { |row| row[:name] == "mds_stores" }[:session]).to eq("")
  end

  it "keeps the top classes only, busiest first" do
    expect(process_classes.rows(top: 2).map { |row| row[:name] }).to eq(%w[yes mds_stores])
  end

  it "says the busiest class in one line" do
    expect(process_classes.line).to eq("Busiest: yes x24, 1032.0% CPU, session s1")
  end

  it "answers the rows through the Sampling adapter" do
    adapter = Hecks::Adapters::MachineSampling.new(settings: { processes: process_classes })
    expect(adapter.busiest.first[:name]).to eq("yes")
  end
end
