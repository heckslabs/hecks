# frozen_string_literal: true

require "spec_helper"
require "json"

# The Pipeline Timeline through the booted Hecks domain, in Memory: one Entry per change per source
# event, a kind from the fixed list, and the time taken from the caller, never a clock.
RSpec.describe "Pipeline timeline" do
  before(:all) do
    @hecks = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_driving: false)
  end

  def launch(*argv) = Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")

  def record(change, kind, source)
    launch("pipeline", "Timeline.record!", "change.value=#{change}", "kind.value=#{kind}",
           "source.value=#{source}", "at.value=2026-11-06T10:00:00Z", "--wait").join
  end

  def entries(change) = JSON.parse(launch("pipeline", "Timeline.for_change", "change.value=#{change}").first)

  it "records an entry with the time of its source event", :aggregate_failures do
    record("t-one", "landed", "Landing.LandedWorkFound/1")
    expect(entries("t-one")).to contain_exactly(include("kind" => "landed", "at" => "2026-11-06T10:00:00Z"))
  end

  it "records one entry per change for one source event", :aggregate_failures do
    record("t-a", "pushed", "Integration.MainPushed/9")
    record("t-b", "pushed", "Integration.MainPushed/9")
    expect(entries("t-a").size + entries("t-b").size).to eq(2)
  end

  it "refuses a kind outside the list" do
    expect(record("t-bad", "teleported", "Nowhere/1")).not_to include("EntryRecorded")
  end
end
