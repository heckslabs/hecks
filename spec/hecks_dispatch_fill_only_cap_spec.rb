require "spec_helper"
require "json"
require "hecks/hecks/adapters/dispatching"

# A `Dispatch.fill!` held to one work item with `only`, read through the launcher as a person types
# it. The queue holds more planned work items than the cap, and the one named sorts after the first
# eight, so the prefix must narrow the candidates before the cap is counted. The whole Hecks domain
# boots in Memory; the `Dispatching` port is the real adapter over stand-in work items and a
# stand-in runner, so no session starts and no live store is read.
RSpec.describe "a filling held to one work item, read through the launcher" do
  def item(key) = Hecks::Adapters::Dispatching::Plan::Item.new(key: key, title: key, detail: "", area: [key])

  # Twelve planned work items ahead of the one named, and three already started.
  def work_items
    planned = (1..12).map { |index| item(format("aa-%02d", index)) } + [item("zz-target")]
    instance_double(Hecks::Adapters::Dispatching::WorkItems, planned: planned, runs: {}, lessons: [],
                                                            started: %w[s-1 s-2 s-3].map { |key| item(key) })
  end

  # The launcher's stand-in: compose answers a brief and every other command succeeds.
  def runner
    lambda do |argv|
      out = argv.include?("Brief.compose!") ? JSON.generate("state" => { "outcome" => "x" }) : ""
      Hecks::Adapters::Shell::Result.new(out, "", instance_double(Process::Status, success?: true))
    end
  end

  def stand_in
    Hecks::Adapters::Dispatching.new(settings: { load: -> { 1.5 }, cpus: 4, work_items: work_items, runner: runner })
  end

  # The settled record a command line answers, without `--wait`.
  def fill(*words)
    runtime = boot_hecks_in_memory
    adapter = stand_in
    text, = Hecks::Runtime::AdapterLookup.standing_in(->(_port, _asked) { adapter }) do
      Hecks::Adapters::Driving::CliRunner.call(runtime: runtime, argv: ["Dispatch.fill!", "repo.value=/repo", *words])
    end
    JSON.parse(text).fetch("state")
  end

  it "starts the named work item while the cap has room, and answers the report it recorded", :aggregate_failures do
    state = fill("only.value=zz-target", "confirm.value=true")

    expect(state["status"]).to eq("answered")
    expect(state["report"]).to include("cap 8, 3 started", "1 to start", "started zz-target")
  end

  it "says without confirm that the named work item would start, and nothing else", :aggregate_failures do
    report = fill("only.value=zz-target")["report"]

    expect(report).to include("would start zz-target")
    expect(report).not_to include("aa-", "cap 8 reached")
  end

  it "previews the named work item as one to start" do
    text = stand_in.preview(repo: { value: "/repo" }, only: { value: "zz-target" })[:text]

    expect(text).to include("1 to start", "would start zz-target")
  end

  it "still holds a plain filling to the cap, in plan order", :aggregate_failures do
    report = fill["report"]

    expect(report).to include("5 to start", "would start aa-05")
    expect(report).to include("zz-target skipped: cap 8 reached (8 started or chosen)")
  end
end
