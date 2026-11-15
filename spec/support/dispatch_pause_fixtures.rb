require "json"
require_relative "roll_forward_fixtures"
require "hecks/hecks/adapters/dispatching"

# Stand-ins for the pause specs: a filling over two planned work items and a launcher that starts
# nothing, built over a Tickets world that says whatever the example gives it.
module DispatchPauseFixtures
  include RollForwardFixtures

  def pause_item(key) = Hecks::Adapters::Dispatching::Plan::Item.new(key: key, title: key, detail: "", area: [key])

  def pause_runner
    lambda do |argv|
      out = argv.include?("Brief.compose!") ? JSON.generate("state" => { "outcome" => "x" }) : ""
      Hecks::Adapters::Shell::Result.new(out, "", instance_double(Process::Status, success?: true))
    end
  end

  def filling(world)
    items = instance_double(Hecks::Adapters::Dispatching::WorkItems, planned: [pause_item("zz-named"), pause_item("aa-other")],
                                                                     started: [], lessons: [], runs: {})
    Hecks::Adapters::Dispatching.new(registry: registry_of([], world),
                                     settings: { load: -> { 0.5 }, cpus: 4, cap: 8, runner: pause_runner, work_items: items })
  end

  def named_fill(world)
    filling(world).choose(run: { value: "f" }, repo: { value: "/repo" }, only: { value: "zz-named" },
                          confirm: { value: true })[:report][:value]
  end

  def window_open(open)
    allow(Hecks::Adapters::Dispatching::WindowStanding).to receive(:open?).and_return(open)
  end
end
