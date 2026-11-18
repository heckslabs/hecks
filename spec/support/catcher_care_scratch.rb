require "tmpdir"

# Helpers for the spec of a beat that runs the Catcher: a scratch file standing in for the
# Catcher's database, and a booted Hecks whose two ports are the real adapters over it.
module CatcherCareScratch
  def idle_file(minutes)
    File.write(path, "")
    File.utime(Time.now - (minutes * 60), Time.now - (minutes * 60), path)
  end

  def beat(runner: ->(argv) { asked << argv })
    registry = boot_hecks_in_memory(File.expand_path("../../lib/hecks/hecks", __dir__)).registry
    ports = ports_over(registry, runner)
    Hecks::Runtime::AdapterLookup.standing_in(->(port, _asked) { ports[port.to_s] }) { dispatch(registry) }
    registry.event_log.map(&:name)
  end

  def ports_over(registry, runner)
    { "Resting" => Hecks::Adapters::CatcherWeighing.new(registry: registry, settings: { path: path }),
      "Running" => Hecks::Adapters::CatcherRunning.new(settings: { runner: runner }) }
  end

  def dispatch(registry)
    Hecks::Runtime::Dispatcher.new(registry).dispatch_flat("Hecks::Heartbeat.Beat", beat: { value: "beat-1" })
  end
end
