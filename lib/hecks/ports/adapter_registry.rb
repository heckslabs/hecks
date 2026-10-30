require_relative "../runtime/errors"

module Hecks
  module Ports
    # The adapter registry (ADR 0161): the one place an adapter records the name it is bound by
    # and the capabilities it provides. A gem calls {register} when it loads, so an adapter
    # package does not have to live under `Hecks::Adapters`.
    #
    # The capability list is closed. Adding one is a bluebook change, so a typo in `provides:`
    # is refused here rather than failing quietly at boot.
    #
    # @example
    #   Hecks::Ports::AdapterRegistry.register("Sqlite", Hecks::Adapters::Sqlite, provides: ["persistence"])
    #   Hecks::Ports::AdapterRegistry.lookup("persistence") # => [["Sqlite", Hecks::Adapters::Sqlite]]
    module AdapterRegistry
      # The capabilities an adapter may provide (ADR 0161).
      CAPABILITIES = %w[
        persistence lineage saga_store outbox read_model loading identity clock remote_dispatch
      ].freeze

      @registrations = {}

      module_function

      # Records an adapter under its bound name. Registering a name again replaces the earlier
      # entry, so reloading an adapter file does not stack duplicates.
      #
      # @param name [String] the adapter's declared name, as a hecksagon binds it
      # @param klass [Class] the adapter class
      # @param provides [Array<String>] the capabilities it provides, from {CAPABILITIES}
      # @return [Class] the adapter class
      # @raise [Runtime::WiringError] if `provides` is empty or names an unknown capability
      def register(name, klass, provides:)
        unknown = Array(provides) - CAPABILITIES
        raise Runtime::WiringError, "#{name} provides unknown capabilities #{unknown.join(", ")}" if unknown.any?
        raise Runtime::WiringError, "#{name} provides no capability" if Array(provides).empty?

        @registrations[name] = { klass: klass, provides: Array(provides).freeze }.freeze
        klass
      end

      # @param capability [String] one of {CAPABILITIES}
      # @return [Array<Array(String, Class)>] the name and class of each adapter that provides it,
      #   sorted by name
      def lookup(capability)
        @registrations
          .select { |_, entry| entry[:provides].include?(capability) }
          .sort_by(&:first)
          .map { |name, entry| [name, entry[:klass]] }
      end

      # @return [Hash{String => Hash}] every registered adapter, keyed by its name
      def all = @registrations.dup

      # Forgets every registration. For specs that register adapters of their own.
      #
      # @return [void]
      def reset!
        @registrations = {}
      end
    end
  end
end
