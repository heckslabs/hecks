require_relative "registry/retired_adapter_rule"

module Hecks
  module Runtime
    # The one place the runtime turns a declared adapter name into the class behind it.
    #
    # A hecksagon binds adapters by name (`persisted_by "Postgres"`), and an adapter's class is
    # the constant of that name under `Hecks::Adapters`, whether the gem or an application
    # defines it. Every other runtime file asks the registry, which asks here, so the runtime
    # never names an adapter itself.
    #
    # @example
    #   AdapterNamespace.resolve("Memory")  # => Hecks::Adapters::Memory
    module AdapterNamespace
      module_function

      # A removed adapter's name is refused here, so the class it left behind is reached only as
      # the layout a hecksagon chooses (`Registry::RetiredAdapterRule`).
      #
      # @param name [String] the adapter's declared name
      # @return [Class] the adapter class of that name
      # @raise [NameError] if no adapter class has that name
      # @raise [WiringError] if the name is a removed adapter's, naming its replacement
      def resolve(name)
        Registry::RetiredAdapterRule.refuse_lookup!(name)
        Hecks::Adapters.const_get(name)
      end
    end
  end
end
