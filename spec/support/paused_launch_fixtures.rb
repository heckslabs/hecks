require "json"
require_relative "dispatch_pause_fixtures"

# Stand-ins for the paused-fill specs: a launcher whose start the owner's pause stops after the
# work item reaches started, and a fill that records every command it runs.
module PausedLaunchFixtures
  include DispatchPauseFixtures

  def calls = (@calls ||= [])

  def stopped_start
    state = JSON.generate("state" => { "work" => "zz-named", "status" => "started" })
    err = "reaction CheckCapWhenWorkStarted was refused: new work is stopped: dispatch_roll_forward is off\n"
    Hecks::Adapters::Shell::Result.new(state, err, instance_double(Process::Status, success?: false))
  end

  def recording(stop_start: false)
    lambda do |argv|
      calls << argv
      stop_start && argv.include?("Work.start!") ? stopped_start : pause_runner.call(argv)
    end
  end

  def fill_with(runner)
    items = instance_double(Hecks::Adapters::Dispatching::WorkItems, planned: [pause_item("zz-named"), pause_item("aa-other")],
                                                                     started: [], lessons: [], runs: {})
    Hecks::Adapters::Dispatching.new(registry: registry_of([], { roll_forward: true }),
                                     settings: { sprint: false, load: -> { 0.5 }, cpus: 4, cap: 8,
                                                 runner: runner, work_items: items })
  end

  def confirmed(adapter, **held)
    adapter.choose(run: { value: "f" }, repo: { value: "/repo" }, confirm: { value: true }, **held)[:report][:value]
  end

  def verbs = calls.filter_map { |argv| argv.find { |word| word.end_with?("!") } }
end
