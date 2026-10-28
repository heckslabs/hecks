require_relative "runtime/registry"
require_relative "sentence_form"

module Hecks
  # Registry of framework bluebooks (Governance, Identity, ...) in `lib/hecks/framework/bluebook/`.
  # Members are derived from the directory and named by capitalized file stem.
  module Framework
    # Directory the members load from, never a copy, so relocated domain copies still resolve.
    # Lives under `lib/` because consumers vendor only `lib/`.
    # Only the bluebook loads: persistence is the consumer's own `Hecks.hecksagon` block.
    ROOT = File.expand_path("framework/bluebook", __dir__).freeze

    # Every framework member available to attach, by declared name.
    #
    # @return [Hash{String => String}] each member's capitalized bluebook name,
    #   mapped to the absolute path of its `.bluebook` file
    def self.members
      Dir.glob(File.join(ROOT, "*.bluebook")).to_h do |path|
        [Naming.pascal(File.basename(path, ".bluebook")), path]
      end
    end

    # Every member whose bluebook declares `provides capability`, read from its IR, not its name.
    #
    # @param capability [String, Symbol] the capability name to look for
    # @return [Array<String>] the names of every framework member that provides it,
    #   sorted
    def self.providers_of(capability)
      members.keys.select { |name| chapter(name).provides?(capability) }.sort
    end

    # One member's bluebook, built in isolation.
    #
    # @param name [String, Symbol] the member's name, such as `"Governance"`
    # @return [Bluebook::Declaration] the member's bluebook, loaded into a scratch registry
    # @raise [Runtime::WiringError] if no framework member has that name
    def self.chapter(name)
      path = members.fetch(name.to_s) do
        raise Runtime::WiringError,
              "no framework member named #{name.inspect} — known: #{members.keys.sort.join(", ")}"
      end

      scratch_registry(path).bluebook(name.to_s)
    end

    # @param path [String] a member's bluebook file
    # @return [Runtime::Registry] a fresh registry holding only that member's bluebook
    def self.scratch_registry(path)
      lib = File.expand_path("..", __dir__)
      registry = Runtime::Registry.new
      Hecks.with_registry(registry) do
        # A bluebook needs these four to build (predicate source is recovered via extraction).
        Kernel.load(File.join(lib, "hecks/ports/persistence.port"))
        Kernel.load(File.join(lib, "hecks/ports/extraction.port"))
        Kernel.load(File.join(lib, "hecks/adapters/driven/memory.adapter"))
        Kernel.load(File.join(lib, "hecks/adapters/driven/prism.adapter"))
        SentenceForm.load_file(path)
      end
      registry
    end
    private_class_method :scratch_registry

    # Loads a member's bluebook unless this registry already holds it.
    #
    # `Kernel.load` re-executes the file, and a second `Declare` of the same aggregate is
    # `AlreadyExists`, so repeated `attaches` calls in one boot must skip.
    #
    # @param name [String, Symbol] the member's name, such as `"Governance"`
    # @return [Boolean, nil] true when this call loaded the member's bluebook, nil when
    #   the current registry already held it
    # @raise [Runtime::WiringError] if no framework member has that name
    def self.load!(name)
      path = members.fetch(name.to_s) do
        raise Runtime::WiringError,
              "no framework member named #{name.inspect} — known: #{members.keys.sort.join(", ")}"
      end

      return if Hecks.current_registry.bluebook(name.to_s)

      SentenceForm.load_file(path)
      load_wiring(path)
    end

    # Loads what a member ships beside its bluebook, as {Bluebooks} does for the bluebooks it
    # carries: `<name>.ports.hecksagon` (the ports it declares) and `<name>.*.adapter` (the
    # adapters binding them). A member with neither loads exactly the bluebook, as before.
    #
    # @param path [String] the member's bluebook file
    # @return [void]
    def self.load_wiring(path)
      stem = File.join(File.dirname(path), File.basename(path, ".bluebook"))
      ports = "#{stem}.ports.hecksagon"
      Kernel.load(ports) if File.file?(ports)
      Dir.glob("#{stem}.*.adapter").each { |adapter| Kernel.load(adapter) }
    end
    private_class_method :load_wiring
  end
end
