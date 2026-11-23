require "spec_helper"
require "json"
require_relative "support/dispatch_pause_fixtures"

# A paused fill starts no session: the owner's pause is read before a coder is dispatched, so a
# work item whose start was stopped by the pause is yielded without an `AgentRun`, and a pause that
# lands mid-fill leaves the work items not yet started waiting in the plan.
RSpec.describe "a paused fill", :aggregate_failures do
  include DispatchPauseFixtures

  let(:calls) { [] }

  def stopped_start
    state = JSON.generate("state" => { "work" => "zz-named", "status" => "started" })
    err = "reaction CheckCapWhenWorkStarted was refused: new work is stopped: dispatch_roll_forward is off\n"
    Hecks::Adapters::Shell::Result.new(state, err, instance_double(Process::Status, success?: false))
  end

  def runner_after_stopped_start
    lambda do |argv|
      calls << argv
      next stopped_start if argv.include?("Work.start!")

      pause_runner.call(argv)
    end
  end

  def fill_with(runner)
    items = instance_double(Hecks::Adapters::Dispatching::WorkItems, planned: [pause_item("zz-named"), pause_item("aa-other")],
                                                                     started: [], lessons: [], runs: {})
    Hecks::Adapters::Dispatching.new(registry: registry_of([], { roll_forward: true }),
                                     settings: { load: -> { 0.5 }, cpus: 4, cap: 8, runner: runner, work_items: items })
  end

  def confirmed(adapter, **held)
    adapter.choose(run: { value: "f" }, repo: { value: "/repo" }, confirm: { value: true }, **held)[:report][:value]
  end

  def verbs = calls.filter_map { |argv| argv.find { |word| word.end_with?("!") } }

  it "launches no run for a work item whose start the pause stopped, and yields it" do
    report = confirmed(fill_with(runner_after_stopped_start), only: { value: "zz-named" })

    expect(report).to include("yielded zz-named: new work is stopped")
    expect(verbs).not_to include("AgentRun.dispatch!")
  end

  it "launches no run and yields nothing for a work item left waiting when the pause lands mid-fill" do
    allow(Hecks::Adapters::WorkLimits).to receive(:switch_on?).and_return(true, false)
    report = confirmed(fill_with(lambda { |argv|
      calls << argv
      pause_runner.call(argv)
    }))

    expect(report).to include("waits: new work is stopped")
    expect(verbs).not_to include("AgentRun.dispatch!", "Work.start!", "Work.yield!")
  end
end
