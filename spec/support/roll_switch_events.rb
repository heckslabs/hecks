require_relative "roll_forward_fixtures"
require_relative "shed_looks"

# Events that would roll the queue, dispatched against the booted Hecks domain in Memory. The
# Tickets world is a hash a spec changes between events, read by the real Rolling adapter; the
# sessions behind every other port are stand-ins.
module RollSwitchEvents
  include RollForwardFixtures

  def hecks = (@hecks ||= boot_hecks_in_memory)

  def world = (@world ||= { roll_forward: false })

  def sessions = (@sessions ||= ShedLooks::Sessions.new)

  def names = hecks.registry.event_log.map(&:name)

  def ports(&)
    wiring = ->(port, _asked) { port.to_s == "Rolling" ? rolling(world) : sessions }
    Hecks::Runtime::AdapterLookup.standing_in(wiring, &)
  end

  # Starts a run and ends it done, so `SessionFinished` is recorded.
  def end_run(key)
    here = { value: Dir.pwd }
    ports do
      hecks.dispatch_flat("Hecks::AgentRun.Dispatch", run: { value: key }, repo: here, brief: { value: "work" })
      hecks.dispatch_flat("Hecks::AgentRun.Finish", agent_run: key, condition: { value: "done" },
                                                    detail: { value: "ended" }, checkout: here)
    end
  end

  def plan(key)
    ports do
      hecks.dispatch_flat("Tickets::Work.Plan", work: { value: key }, title: { value: key }, detail: { value: "d" }, area: [])
    end
  end

  def switch_record
    registry = hecks.registry
    registry.repository("Hecks", registry.bluebook("Hecks").aggregate("RollSwitch")).find("rolls")
  end
end
