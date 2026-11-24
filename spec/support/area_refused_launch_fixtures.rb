require_relative "paused_launch_fixtures"

# Stand-ins for the area-refused-start specs: a launcher whose start reaches started and then has
# its area claim refused, so the work item is yielded in the same breath.
module AreaRefusedLaunchFixtures
  include PausedLaunchFixtures

  def area_refused_start
    state = JSON.generate("state" => { "work" => "zz-named", "status" => "started" })
    err = "reaction CheckAreaWhenStarted was refused: zz-named cannot claim lib/hecks/agents: " \
          "aa-other holds lib/hecks/agents/adapters\n"
    Hecks::Adapters::Shell::Result.new(state, err, instance_double(Process::Status, success?: false))
  end

  def area_refusing
    lambda do |argv|
      calls << argv
      argv.include?("Work.start!") ? area_refused_start : pause_runner.call(argv)
    end
  end
end
