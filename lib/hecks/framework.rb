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
      members.keys.select { |name| declaration(name).provides?(capability) }.sort
    end

    # One member's bluebook, built in isolation.
    #
    # @param name [String, Symbol] the member's name, such as `"Governance"`
    # @return [Bluebook::Declaration] the member's bluebook, loaded into a scratch registry
    # @raise [Runtime::WiringError] if no framework member has that name
    def self.declaration(name)
      path = members.fetch(name.to_s) do
        raise Runtime::WiringError,
              "no framework member named #{name.inspect} — known: #{members.keys.sort.join(", ")}"
      end

      scratch_registry(path).bluebook(name.to_s)
    end

    # The values a closed-set value object declares in a framework member, so the code that checks
    # a value reads the list from the bluebook and holds no copy. The member loads once per
    # process.
    #
    # @param member [String] the member's name, such as `"Governance"`
    # @param aggregate [String] the aggregate holding the value object
    # @param value_object [String] the value object declaring `one_of`
    # @return [Array<String>] the members of the set, frozen
    # @raise [Runtime::WiringError] if the member, aggregate or value object is not declared
    def self.closed_set(member, aggregate, value_object)
      @closed_sets ||= {}
      @closed_sets[[member, aggregate, value_object]] ||= set_members(member, aggregate, value_object)
    end

    # @return [Array<String>] the members of one declared closed set, frozen
    def self.set_members(member, aggregate, value_object)
      @declarations ||= {}
      held = (@declarations[member.to_s] ||= declaration(member))
      closed_values(held, aggregate, value_object)
    end
    private_class_method :set_members

    # One command a framework member declares, with its givens, read from the member's bluebook.
    # The member loads once per process, as `closed_set`'s does.
    #
    # @param member [String] the member's name, such as `"Governance"`
    # @param aggregate [String] the aggregate declaring the command
    # @param command [String] the command, such as `"Admit"`
    # @return [Bluebook::Command] the declared command, memoized
    # @raise [Runtime::WiringError] if the member, aggregate or command is not declared
    def self.command_of(member, aggregate, command)
      @commands ||= {}
      @commands[[member, aggregate, command]] ||= begin
        declared = declaration(member).aggregate(aggregate)&.command(command)
        declared || raise(Runtime::WiringError, "#{member} declares no #{aggregate}.#{command} command")
      end
    end

    # The values a closed-set value object declares in any loaded bluebook.
    #
    # @param declaration [Bluebook::Declaration] the bluebook holding the value object
    # @param aggregate [String] the aggregate holding it
    # @param value_object [String] the value object declaring `one_of`
    # @return [Array<String>] the members of the set, frozen
    # @raise [Runtime::WiringError] if the bluebook declares no such closed set
    def self.closed_values(declaration, aggregate, value_object)
      found = declaration.aggregate(aggregate)&.value_object(value_object)
      raise Runtime::WiringError, "#{declaration.name} declares no #{aggregate}.#{value_object}" unless found&.closed_set?

      values = found.members.flat_map(&:values)
      values.uniq.freeze
    end

    # Any one bluebook file, built in isolation like a member.
    #
    # @param path [String] the bluebook file
    # @param name [String] the name its header declares
    # @return [Bluebook::Declaration] the bluebook, loaded into a scratch registry
    def self.declaration_at(path, name)
      scratch_registry(path).bluebook(name)
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
