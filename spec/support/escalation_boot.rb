# frozen_string_literal: true

# Boots the Agents bluebook in Memory and raises escalations against it, so a spec reads the
# events a wake leaves without touching the live tap or any ledger.
module EscalationBoot
  PARTS = %w[PERSISTENCE_PORT EXTRACTION_PORT MEMORY_ADAPTER PRISM_ADAPTER].freeze
  BLUEBOOK = "lib/hecks/agents/agents.bluebook"

  def boot
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) { sources.each { |file| Kernel.load(file) } }
    @dispatcher = Hecks::Runtime::Dispatcher.new(registry)
    Hecks::Runtime::Loader.bind_runtime(@dispatcher)
  end

  def sources
    PARTS.map { |name| InMemoryDomain.const_get(name) } + [File.join(InMemoryDomain::ROOT, BLUEBOOK)]
  end

  def raise_for(key)
    Hecks::Agents::Escalation.raise!(escalation: { value: key }, event: { value: "StallFiled" },
                                     rule: { value: "rely-on-events" }, role: { value: "orchestrator" },
                                     repo: { value: "." }, brief: { value: "look" })
  end

  def woken
    @dispatcher.events.map { |event| event.respond_to?(:name) ? event.name : event[:name] }.grep(/CoordinatorWoken/)
  end

  def raise_twice(key)
    [1, 2].each { raise_for(key) }
  rescue StandardError
    nil
  end
end
