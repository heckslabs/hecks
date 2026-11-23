# Helpers for the spec of a beat that prunes the Rust build dirs: a booted Hecks whose two ports
# are the real adapters over stand-ins for the volume, gone worktrees, build lock and delete.
module RustCareScratch
  def beat(free_gb: 200, gone: false, locked: false)
    registry = boot_hecks_in_memory(File.expand_path("../../lib/hecks/hecks", __dir__)).registry
    ports = ports_over(registry, { free_gb: free_gb, gone: -> { gone }, locked: -> { locked } })
    Hecks::Runtime::AdapterLookup.standing_in(->(port, _asked) { ports[port.to_s] }) { dispatch(registry) }
    registry.event_log.map(&:name)
  end

  def ports_over(registry, gauge)
    { "Gauging"  => Hecks::Adapters::RustWeighing.new(registry: registry, settings: gauge),
      "Trimming" => Hecks::Adapters::RustPruning.new(settings: { pruner: pruner }) }
  end

  def dispatch(registry)
    Hecks::Runtime::Dispatcher.new(registry).dispatch_flat("Hecks::Heartbeat.Beat", beat: { value: "beat-1" })
  end
end
