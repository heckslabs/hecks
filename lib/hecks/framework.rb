require_relative "runtime/registry"

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

    # One member's chapter, built in isolation.
    #
    # @param name [String, Symbol] the member's name, such as `"Governance"`
    # @return [Bluebook::Chapter] the member's chapter, loaded into a scratch registry
    # @raise [Runtime::WiringError] if no framework member has that name
    def self.chapter(name)
      path = members.fetch(name.to_s) do
        raise Runtime::WiringError,
              "no framework member named #{name.inspect} — known: #{members.keys.sort.join(', ')}"
      end

      lib = File.expand_path("..", __dir__)
      registry = Runtime::Registry.new
      Hecks.with_registry(registry) do
        # A chapter needs these four to build (predicate source is recovered via extraction).
        Kernel.load(File.join(lib, "hecks/ports/persistence.port"))
        Kernel.load(File.join(lib, "hecks/ports/extraction.port"))
        Kernel.load(File.join(lib, "hecks/adapters/driven/memory.adapter"))
        Kernel.load(File.join(lib, "hecks/adapters/driven/prism.adapter"))
        Kernel.load(path)
      end
      registry.bluebook(name.to_s)
    end

    # Loads a member's bluebook unless this registry already holds it.
    #
    # `Kernel.load` re-executes the file, and a second `Declare` of the same aggregate is
    # `AlreadyExists`, so repeated `uses_framework` calls in one boot must skip.
    #
    # @param name [String, Symbol] the member's name, such as `"Governance"`
    # @return [Boolean, nil] true when this call loaded the member's bluebook, nil when
    #   the current registry already held it
    # @raise [Runtime::WiringError] if no framework member has that name
    def self.load!(name)
      path = members.fetch(name.to_s) do
        raise Runtime::WiringError,
              "no framework member named #{name.inspect} — known: #{members.keys.sort.join(', ')}"
      end

      return if Hecks.current_registry.bluebook(name.to_s)

      Kernel.load(path)
    end
  end
end
