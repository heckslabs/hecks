require "spec_helper"
require "json"
require "hecks/hecks/adapters/dispatching"

# A `Dispatch.Fill` reaches its `Choose` ask through the `ChooseWhenFilling` policy, with the
# request's `only` prefix. The whole Hecks domain boots in Memory, as the launcher boots it; the
# `Dispatching` port is answered by the real adapter over stand-in work items, so no session starts.
RSpec.describe "a filling, dispatched through its Choose ask" do
  HECKS_DOMAIN = File.expand_path("../lib/hecks/hecks", __dir__).freeze

  def item(key) = Hecks::Adapters::Dispatching::Plan::Item.new(key: key, title: key, detail: "", area: [key])

  def dispatching(planned)
    items = instance_double(Hecks::Adapters::Dispatching::WorkItems, planned: planned.map { |key| item(key) },
                                                                    started: [], runs: {}, lessons: [])
    Hecks::Adapters::Dispatching.new(settings: { load: -> { 1.5 }, cpus: 4, work_items: items, runner: runner })
  end

  # The launcher's stand-in: every command answers, compose with a brief, and dispatching `gap-b`
  # fails with the reason a session reads.
  def runner
    lambda do |argv|
      out = argv.include?("Brief.compose!") ? JSON.generate("state" => { "outcome" => "x" }) : ""
      failed = argv.include?("run.value=gap-b")
      Hecks::Adapters::Shell::Result.new(out, failed ? "no repo" : "", instance_double(Process::Status, success?: !failed))
    end
  end

  def boot = boot_hecks_in_memory(HECKS_DOMAIN).registry

  def fill(registry, planned, **args)
    stand_in = dispatching(planned)
    request = { run: { value: "run-1" }, repo: { value: "/repo" } }.merge(args)
    Hecks::Runtime::AdapterLookup.standing_in(->(_port, _asked) { stand_in }) do
      Hecks::Runtime::Dispatcher.new(registry).dispatch_flat("Hecks::Dispatch.Fill", **request)
    end
    registry
  end

  def events_named(registry, name) = registry.event_log.select { |event| event.name == name }

  def report_of(registry)
    payload = events_named(registry, "DispatchReported").last.payload
    payload.fetch(:report).fetch(:value)
  end

  let(:planned) { %w[gap-a gap-b other] }

  it "chooses only the planned work items whose key starts with the prefix", :aggregate_failures do
    report = report_of(fill(boot, planned, only: { value: "gap-a" }))

    expect(report).to include("would start gap-a")
    expect(report).not_to include("gap-b", "other")
  end

  it "still chooses from every planned work item when no prefix is named", :aggregate_failures do
    report = report_of(fill(boot, planned))

    expect(report).to include("would start gap-a", "would start other")
  end

  it "records a confirmed filling's report with one line for each chosen work item", :aggregate_failures do
    registry = fill(boot, planned, only: { value: "gap" }, confirm: { value: true })
    recorded = Hecks::Runtime::Value.materialize(events_named(registry, "DispatchAnswered").last.payload[:report])

    expect(recorded.to_s).to include("started gap-a", "yielded gap-b: dispatch of gap-b failed: no repo")
    expect(report_of(registry)).not_to include("would start")
  end

  it "is refused at no point: Choose answers and nothing is refused", :aggregate_failures do
    registry = fill(boot, planned, only: { value: "gap-a" })

    expect(events_named(registry, "DispatchRefused")).to be_empty
    expect(events_named(registry, "DispatchReported")).not_to be_empty
  end

  # A `Dispatch.Preview` answers the report a filling would give, read from the same plan and
  # launching nothing: its lines are the lines a dry filling reports.
  describe "previewing a filling" do
    it "reports which planned work items would start, with the prefix applied", :aggregate_failures do
      text = dispatching(planned).preview(repo: { value: "/repo" }, only: { value: "gap-a" })[:text]

      expect(text).to include("would start gap-a")
      expect(text).not_to include("gap-b", "other")
    end

    it "answers the lines a dry filling reports" do
      stand_in = dispatching(planned)
      filling = stand_in.choose(run: { value: "run-1" }, repo: { value: "/repo" })[:report][:value]

      expect(stand_in.preview(repo: { value: "/repo" })[:text]).to eq("#{filling}\n")
    end
  end
end
