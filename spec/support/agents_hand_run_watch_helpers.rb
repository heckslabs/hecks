require "json"
require_relative "agents_message_helpers"
require_relative "agents_fleet_helpers"

# Watches the registered hand runs on the booted Agents bluebook against a stand-in `claude agents`
# listing the example sets, and restarts through a recording shell that runs no `claude` command.
module AgentsHandRunWatchHelpers
  include AgentsMessageHelpers

  PORTS = (AgentsMessageHelpers::PORTS + [
    File.join(InMemoryDomain::ROOT, "lib/hecks/agents/adapters/fleet_control.adapter"),
    File.join(InMemoryDomain::ROOT, "lib/hecks/agents/adapters/hand_run_watch.adapter")
  ]).freeze

  # The sessions `claude agents` lists now; an example changes it between beats.
  def sessions = (@sessions ||= [])

  def listed_sessions = sessions.map { |entry| entry["sessionId"] }

  def recipients = {}

  def session_entry(id, name, state = "working")
    { "id" => id[0, 8], "sessionId" => id, "name" => name, "state" => state, "status" => "idle" }
  end

  def shell = (@shell ||= AgentsFleetHelpers::RecordingShell.new(sessions))

  def watch_adapter = Hecks::Adapters::HandRunWatch.new(listing: -> { sessions })

  def fleet_adapter
    Hecks::Adapters::FleetControl.new(settings: { shell: shell, projects: Dir.tmpdir, runs: -> { { runs: {}, sessions: {}, pinned: [] } } })
  end

  def adapters
    { "HandRunWatching" => watch_adapter, "Fleet" => fleet_adapter, "Recipients" => recipient_check, "Rousing" => role_rouser }
  end

  def boot_watch = (@agents_runtime = AgentsMemoryBoot.call(extra: PORTS))

  # One beat of the clock: every registered hand run is looked at, lost ones restarted.
  def beat(key)
    Hecks::Runtime::AdapterLookup.standing_in(->(port, _asked) { adapters.fetch(port.to_s) }) do
      Hecks::Agents::HandRunWatch.watch!(pass: { value: key })
    end
  end

  def hand(run) = Hecks::Agents::HandRun.find(run)
end
