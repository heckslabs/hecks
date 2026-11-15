require "hecks/hecks/adapters/machine_sampling"

# A Memory registry holding Machine readings, for the specs of the sampling port's history.
module MachineHistoryRows
  Row = Struct.new(:id, :state)

  # Boots the Hecks domain in Memory and saves `count` readings, oldest first, the last one standing
  # in the states the history should find.
  #
  # @param count [Integer] how many readings to hold
  # @return [Hecks::Adapters::MachineSampling::History] a history over that registry
  def history_over(count)
    registry = boot_hecks_in_memory(File.expand_path("../../lib/hecks/hecks", __dir__)).registry
    repository = registry.repository("Hecks", machine_of(registry))
    count.times { |index| repository.save(reading(index, count)) }
    Hecks::Adapters::MachineSampling::History.new(registry)
  end

  # A history over a SQLite table in a temporary directory, which decodes each row it lists.
  #
  # @param count [Integer] how many readings to hold
  # @param dir [String] a temporary directory for the database file
  # @return [Hecks::Adapters::MachineSampling::History]
  def sqlite_history_over(count, dir)
    booted = boot_hecks_in_memory(File.expand_path("../../lib/hecks/hecks", __dir__)).registry
    store = Hecks::Adapters::Sqlite.new(aggregate: machine_of(booted), settings: { database: "machine.db" }, root: dir)
    count.times { |index| store.save(reading(index, count)) }
    Hecks::Adapters::MachineSampling::History.new(HeldRegistry.new(booted.bluebook("Hecks"), store))
  end

  HeldRegistry = Struct.new(:held, :store) do
    def bluebook(_name) = held

    def repository(*) = store
  end

  def machine_of(registry) = registry.bluebook("Hecks").aggregates.find { |each| each.hecks_name == "Machine" }

  def reading(index, count)
    newest = index == count - 1
    Row.new("beat-#{index}", { run: "beat-#{index}", load_state: newest ? "above" : "below",
                               memory_state: "low", lane_state: "idle" })
  end

  # @return [Float] milliseconds one call of the block takes, the best of five
  def best_ms(&)
    Array.new(5) { elapsed_ms(&) }.min
  end

  def elapsed_ms
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
  end
end
