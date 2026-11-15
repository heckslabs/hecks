# What the verdict mix spec drives: the Agents bluebook booted into a registry the spec holds, and
# the `VerdictMix` read model run against it.
module VerdictMixHelpers
  def boot_into(registry)
    Hecks.with_registry(registry) do
      [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT, InMemoryDomain::MEMORY_ADAPTER,
       InMemoryDomain::PRISM_ADAPTER, File.join(agents_root, "agents.bluebook")].each { |file| Kernel.load(file) }
    end
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  def answer_with(run, word)
    request(run: run).answer!(verdict: { value: word })
  end

  def mix
    model = registry.bluebook("Agents").read_models.find { |candidate| candidate.name.to_s == "VerdictMix" }
    answer = Hecks::Runtime::ReadModelInterpreter.new(registry).call("Agents", model, {})
    answer.first.values.first.to_h { |group, count| [group.to_s, count] }
  end
end
