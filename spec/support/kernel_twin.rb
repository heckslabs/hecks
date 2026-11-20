require "json"
require "tmpdir"

# Runs the same steps through the in-process engine and the kernel engine, for the twin specs.
# Each example gets a temporary event tap, so no kernel boot reaches the owner's live tap.
module KernelTwin
  STAMP = "2026-01-01T00:00:00Z".freeze

  # Gives each example its own event tap and one bound clock.
  def self.included(group)
    group.around do |example|
      Dir.mktmpdir("kernel-twin") do |dir|
        previous = ENV.fetch("HECKS_EVENT_TAP", nil)
        ENV["HECKS_EVENT_TAP"] = File.join(dir, "events.jsonl")
        example.run
      ensure
        ENV["HECKS_EVENT_TAP"] = previous
      end
    end
    group.before { allow(Hecks::Runtime::Event).to receive(:stamp).and_return(STAMP) }
  end

  # @param dir [String] a domain directory
  # @param engine [Symbol] `:ruby` or `:kernel`
  # @yieldparam dispatcher [Object] the booted dispatcher; a kernel one is closed afterwards
  # @return [Object] the block's value
  def on_engine(dir, engine)
    dispatcher = Hecks.boot(dir, install_driving: false, engine: engine)
    yield dispatcher
  ensure
    dispatcher.close if engine == :kernel && dispatcher.respond_to?(:close)
  end

  # Boots a Memory copy of a domain whose own persistence is not Memory, so the kernel engine
  # takes it; the kernel binary is the domain's own feature build.
  #
  # @param dir [String] a domain directory
  # @param engine [Symbol] `:ruby` or `:kernel`
  # @yieldparam dispatcher [Object] the booted dispatcher; a kernel one is closed afterwards
  # @return [Object] the block's value
  def on_memory_copy(dir, engine, &)
    Hecks::Fuzzing::IsolatedBoot.call(dir) do |copy|
      next on_engine(copy, :ruby, &) if engine == :ruby

      on_kernel(copy, Hecks::RustBuild::KernelEngine.binary_for(File.basename(dir)), &)
    end
  end

  # @return [Object] the block's value, given a kernel dispatcher over `binary` for `dir`
  def on_kernel(dir, binary)
    dispatcher = Hecks::RustBuild::KernelEngine.boot(dir, binary: binary)
    yield dispatcher
  ensure
    dispatcher&.close
  end

  # @return [Array<Hash>] each event as canonical JSON: name, aggregate, id, attributes, stamp
  def canonical(events)
    events.map do |event|
      JSON.parse(JSON.generate("name" => event.name.to_s, "aggregate" => event.aggregate.to_s,
                               "id" => event.id.to_s, "attributes" => event.payload,
                               "occurred_at" => event.occurred_at.to_s))
    end
  end

  # @return [Array(String, String), Symbol] the error's bare class name and message, or `:ok`
  def outcome
    yield
    :ok
  rescue StandardError => e
    [e.class.name.split("::").last, e.message]
  end

  # @return [String, Symbol] the refusal's message alone, or `:ok`
  def refusal_text(&)
    answered = outcome(&)
    answered == :ok ? :ok : answered.last
  end
end
