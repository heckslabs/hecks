# Hecks::Runtime::ConfigurationDSL
#
# Configuration methods evaluated inside the runtime boot block.
# Allows adapter overrides, middleware registration, and option flags.
#
#   app = Hecks.load(domain) do
#     adapter "Pizza", my_sql_repo
#     enable "Document", :versioned
#     use(:logging) { |cmd, nxt| puts cmd; nxt.call }
#   end
#
module Hecks
  class Runtime
    module ConfigurationDSL
      # Register command bus middleware.
      #
      # @param name [Symbol, String, nil] optional middleware name
      # @yield block receiving (command, next_handler)
      # @return [void]
      def use(name = nil, &block)
        @command_bus.use(name, &block)
      end

      # Override the default memory adapter for a specific aggregate.
      #
      # @param aggregate_name [String, Symbol] the aggregate name
      # @param adapter_obj [Object] a repository object
      # @return [void]
      def adapter(aggregate_name, adapter_obj)
        @adapter_overrides[aggregate_name.to_s] = adapter_obj
      end

      # Enable an infrastructure option for a specific aggregate.
      #
      # @param aggregate_name [String, Symbol] the aggregate name
      # @param option [Symbol] the option to enable
      # @return [void]
      def enable(aggregate_name, option)
        name = aggregate_name.to_s
        @runtime_options[name] ||= {}
        @runtime_options[name][option] = true
      end

      # Replace a repository adapter after boot.
      #
      # @param aggregate_name [String, Symbol] the aggregate name
      # @param repo [Object] the replacement repository
      # @return [void]
      def swap_adapter(aggregate_name, repo)
        name = aggregate_name.to_s
        @repositories[name] = repo
        wire_aggregate!(name)
      end
    end
  end
end
