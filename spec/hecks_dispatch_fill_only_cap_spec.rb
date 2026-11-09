require "spec_helper"
require "json"
require "hecks/hecks/adapters/dispatching"

# A `Dispatch.fill!` held to one work item with `only`, read through the launcher as a person types
# it. The queue holds more planned work items than the cap, and the one named sorts after the first
# twelve, so the prefix must narrow the candidates before the cap is counted, and the cap is held
# against the started work items plus the named one, never against other planned work items. The
# whole Hecks domain boots in Memory; the `Dispatching` port is the real adapter over stand-in work
# items and a stand-in runner, so no session starts and no live store is read.
RSpec.describe "a filling held to one work item, read through the launcher" do
  def item(key) = Hecks::Adapters::Dispatching::Plan::Item.new(key: key, title: key, detail: "", area: [key])

  # Twelve planned work items ahead of the one named, and `started` already started.
  def work_items(started)
    planned = (1..12).map { |index| item(format("aa-%02d", index)) } + [item("zz-target")]
    instance_double(Hecks::Adapters::Dispatching::WorkItems, planned: planned, runs: {}, lessons: [],
                                                            started: Array.new(started) { |index| item("s-#{index}") })
  end

  # The launcher's stand-in: compose answers a brief and every other command succeeds.
  def runner
    lambda do |argv|
      out = argv.include?("Brief.compose!") ? JSON.generate("state" => { "outcome" => "x" }) : ""
      Hecks::Adapters::Shell::Result.new(out, "", instance_double(Process::Status, success?: true))
    end
  end

  def stand_in(started: 3, cap: 8)
    Hecks::Adapters::Dispatching.new(settings: { load: -> { 1.5 }, cpus: 4, cap: cap, runner: runner,
                                                 work_items: work_items(started) })
  end

  # The settled record a command line answers, without `--wait`.
  def fill(*words, started: 3, cap: 8)
    runtime = boot_hecks_in_memory
    adapter = stand_in(started: started, cap: cap)
    text, = Hecks::Runtime::AdapterLookup.standing_in(->(_port, _asked) { adapter }) do
      Hecks::Adapters::Driving::CliRunner.call(runtime: runtime, argv: ["Dispatch.fill!", "repo.value=/repo", *words])
    end
    JSON.parse(text).fetch("state")
  end

  it "starts the named work item while the cap has room, and answers the report it recorded", :aggregate_failures do
    state = fill("only.value=zz-target", "confirm.value=true")

    expect(state["status"]).to eq("answered")
    expect(state["report"]).to include("started 3 of cap 8", "this fill: 1 started, 0 yielded of 1", "started zz-target")
  end

  it "says without confirm that the named work item would start, and nothing else", :aggregate_failures do
    report = fill("only.value=zz-target")["report"]

    expect(report).to include("would start zz-target")
    expect(report).not_to include("aa-", "cap 8 reached")
  end

  it "previews the named work item as one to start" do
    text = stand_in.preview(repo: { value: "/repo" }, only: { value: "zz-target" })[:text]

    expect(text).to include("this fill would start 1", "would start zz-target")
  end

  it "still holds a plain filling to the cap, in plan order", :aggregate_failures do
    report = fill["report"]

    expect(report).to include("this fill would start 5", "would start aa-05")
    expect(report).to include("zz-target skipped: cap 8 reached (3 started, 5 chosen by this fill)")
  end

  it "starts the named work item at four started of ten, however many others a plain fill would choose" do
    expect(fill("only.value=zz-target", started: 4, cap: 10)["report"]).to include("started 4 of cap 10", "would start zz-target")
  end

  it "starts the named work item at nine started of ten", :aggregate_failures do
    report = fill("only.value=zz-target", "confirm.value=true", started: 9, cap: 10)["report"]

    expect(report).to include("started 9 of cap 10", "started zz-target")
  end

  it "refuses a named work item at ten started of ten, naming the real count", :aggregate_failures do
    report = fill("only.value=zz-target", "confirm.value=true", started: 10, cap: 10)["report"]

    expect(report).to include("zz-target skipped: cap 10 reached (10 started, 0 chosen by this fill)")
    expect(report).not_to include("started zz-target")
  end
end
