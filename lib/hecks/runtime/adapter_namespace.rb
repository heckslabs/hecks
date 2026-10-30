require_relative "../ports/adapter_registry"

module Hecks
  module Runtime
    # The one place the runtime turns a declared adapter name into the class behind it.
    #
    # A hecksagon binds adapters by name (`persisted_by "Postgres"`). The adapter registry
    # (ADR 0161) is asked first, since an adapter registers itself when it loads. A name it does
    # not hold falls back to the constant of that name under `Hecks::Adapters`, which covers an
    # adapter an application defines and one whose file has not loaded yet.
    #
    # @example
    #   AdapterNamespace.resolve("Memory")  # => Hecks::Adapters::Memory
    module AdapterNamespace
      module_function

      # @param name [String] the adapter's declared name
      # @return [Class] the adapter class of that name
      # @raise [NameError] if no adapter class has that name
      def resolve(name) = Ports::AdapterRegistry.fetch(name) || Hecks::Adapters.const_get(name)
    end
  end
end
