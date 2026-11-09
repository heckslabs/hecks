require "spec_helper"
require "json"
require "hecks/hecks/adapters/dispatching"

# The record `Dispatch.fill! confirm.value=true --wait` prints carries the report the filling
# wrote: one line for each chosen work item. The launcher's commands are answered by a stand-in
# runner; no session starts.
DOMAIN_DIR = File.expand_path("../lib/hecks/hecks", __dir__).freeze

RSpec.describe "a confirmed filling, settled through the launcher" do
  def item(key) = Hecks::Adapters::Dispatching::Plan::Item.new(key: key, title: "Title #{key}", detail: "", area: [key])

  def runner
    lambda do |argv|
      out = argv.include?("Brief.compose!") ? JSON.generate("state" => { "outcome" => "x" }) : ""
      Hecks::Adapters::Shell::Result.new(out, "", instance_double(Process::Status, success?: true))
    end
  end

  def stand_in
    items = instance_double(Hecks::Adapters::Dispatching::WorkItems, planned: %w[gap-a gap-b].map { |key| item(key) },
                                                                    started: [], runs: {}, lessons: [])
    Hecks::Adapters::Dispatching.new(settings: { load: -> { 1.0 }, cpus: 4, work_items: items, runner: runner })
  end

  def settled(*words)
    runtime = Hecks.boot(DOMAIN_DIR, environment: "memory", install_driving: false)
    argv = ["Dispatch.fill!", "repo.value=/repo", *words]
    Hecks::Runtime::AdapterLookup.standing_in(->(_port, _asked) { stand_in }) do
      Hecks::Adapters::Driving::CliRunner.call(runtime: runtime, argv: argv, program: "hecks")
    end
  end

  it "prints the record with the report of what started", :aggregate_failures do
    text, status, reason = settled("confirm.value=true", "--wait")
    record = JSON.parse(text)

    expect([status, reason]).to eq([0, nil])
    expect(record.dig("state", "report")).to include("started gap-a", "started gap-b")
  end

  it "prints the record with the report without --wait too" do
    text, = settled("confirm.value=true")

    expect(JSON.parse(text).dig("state", "report")).to include("started gap-a", "started gap-b")
  end
end
