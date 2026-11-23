# Stand-in machine profiles for the MachineProfile specs: none reads the real machine.
module MachineProfiles
  # @return [Hash] a large machine: 12 performance and 4 efficiency cores
  def big = { performance_cores: 12, efficiency_cores: 4, cores: 16, free_memory_mb: 20_000, resident_mb: 400 }

  # @return [Hash] a smaller machine: 4 performance and 4 efficiency cores
  def small = { performance_cores: 4, efficiency_cores: 4, cores: 8, free_memory_mb: 6_000, resident_mb: 400 }

  # @return [Hash] a machine at the floor of every bound
  def tiny = { performance_cores: 1, efficiency_cores: 0, cores: 1, free_memory_mb: 100, resident_mb: 400 }

  # @return [Array<String>] the settings derived from a profile
  def derived_settings = %w[residents heavy_jobs spec_workers load_low load_high]
end
