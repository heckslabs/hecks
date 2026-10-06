require "tempfile"
require_relative "memory_ports"

# Boots a domain from bluebook source held in a string: the source goes to a temporary file so
# its line numbers and errors point somewhere real, is evaluated at the top level into a fresh
# registry, and the registry is bound to a runtime. Meta-validation is off unless a spec asks
# for it, so a spec can test the interpreter without the grammar's admission rules in the way.
module InlineBluebookBoot
  # @param source [String] the bluebook text
  # @param hecksagon_name [String] the chapter whose ports the block binds
  # @param validate [Boolean] whether the Judge runs while the source loads
  # @yield the hecksagon body, run once the source has been evaluated
  # @return [Hecks::Runtime::Runtime] the booted runtime
  def boot(source, hecksagon_name, validate: false, &binds)
    registry = Hecks::Runtime::Registry.new
    with_bluebook_file(source) do |path|
      judging(validate) { load_inline_domain(registry, source, path) { Hecks.hecksagon(hecksagon_name, &binds) } }
    end
    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  private

  def with_bluebook_file(source)
    file = Tempfile.new(["inline-bluebook-", ".bluebook"])
    file.write(source)
    file.flush
    yield file.path
  ensure
    file&.close!
  end

  def judging(validate, &)
    validate ? yield : Hecks::Bluebook::MetaValidator.while_disabled(&)
  end

  def load_inline_domain(registry, source, path, &)
    Hecks.with_registry(registry) do
      MemoryPorts.load!
      Kernel.eval(source, TOPLEVEL_BINDING, path, 1)
      yield
    end
  end
end
