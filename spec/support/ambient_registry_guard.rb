# Gives every example a sound ambient registry (`Hecks.current_registry`), and names a spec that
# leaves it changed. The registry is process-wide and `Hecks.with_registry` puts it back on exit,
# so a stand-in that is not a `Hecks::Runtime::Registry` can only get there from a binding that
# never returned. It would then fail every later example of the process that builds a bluebook,
# on `record_bluebook_source`. An example starts with the real registry it found, or none, and
# the registry it found is put back when it ends.
module AmbientRegistryGuard
  # Runs the example inside the ambient registry it started with.
  #
  # @param example [RSpec::Core::Example::Procsy] the example to run
  # @return [void]
  def self.around(example)
    held = sound(Hecks.current_registry, example)
    Hecks.with_registry(held) do
      example.run
      leaked(held, example)
    end
  end

  # @param found [Object, nil] the ambient registry at the start of an example
  # @param example [RSpec::Core::Example::Procsy] the example about to run
  # @return [Hecks::Runtime::Registry, nil] `found` when it is a registry, else none
  def self.sound(found, example)
    return found if found.nil? || found.is_a?(Hecks::Runtime::Registry)

    warn "ambient registry was #{found.inspect[0, 60]} before: #{example.full_description}"
  end

  # @param held [Hecks::Runtime::Registry, nil] the registry the example started with
  # @param example [RSpec::Core::Example::Procsy] the example that ran
  # @return [void]
  def self.leaked(held, example)
    return if Hecks.current_registry.equal?(held)

    warn "ambient registry left changed by: #{example.full_description}"
  end
end

RSpec.configure do |config|
  config.around { |example| AmbientRegistryGuard.around(example) }
end
