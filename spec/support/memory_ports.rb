# Loads the persistence and extraction ports with their Memory and Prism adapters into the
# current registry, the preamble every spec that boots a real in-memory domain starts with.
module MemoryPorts
  module_function

  # @return [void]
  def load!
    [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT,
     InMemoryDomain::MEMORY_ADAPTER, InMemoryDomain::PRISM_ADAPTER].each { |file| Kernel.load(file) }
  end
end
