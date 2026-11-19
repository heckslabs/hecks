# Boots the Agents bluebook alone in Memory with its own registry, so an example reaches no
# ledger and no event tap.
module AgentsMemoryBoot
  FILES = [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT, InMemoryDomain::MEMORY_ADAPTER,
           InMemoryDomain::PRISM_ADAPTER, File.join(InMemoryDomain::ROOT, "lib/hecks/agents/agents.bluebook")].freeze

  # @param extra [Array<String>] further files loaded after the bluebook (its ports, an adapter)
  # @return [Object] the runtime bound to the new registry
  def self.call(extra: [])
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) { (FILES + extra).each { |file| Kernel.load(file) } }
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end
end
