module Hecks
  module Ports
    # Holds the persistence-plugin registry and its `register_plugin`/`plugin?`/`each_plugin`
    # surface.
    module Persistence
      # The persistence-plugin registry (ADR 0033). A plugin registers itself when required, and
      # need only respond to `contribute_boot_gates(registry, gates)`; a no-op is valid.
      #
      # Process-wide and name-keyed: a plugin is either required into this process or it is not.
      module Plugin
        @plugins = {}

        class << self
          # Adds a plugin under a name, replacing any plugin already registered under it.
          #
          # @param name [Symbol, String] the plugin's name, such as `:era`; stored as a Symbol
          # @param plugin [Object] anything responding to
          #   `contribute_boot_gates(registry, gates)`
          # @return [Object] the plugin just registered
          def register(name, plugin)
            @plugins[name.to_sym] = plugin
          end

          # Whether a plugin is registered under `name`.
          #
          # @return [Boolean]
          def registered?(name)
            @plugins.key?(name.to_sym)
          end

          # Yields every registered plugin, in registration order.
          def each(&)
            @plugins.each_value(&)
          end

          # Whether at least one plugin is registered.
          #
          # @return [Boolean]
          def any? = !@plugins.empty?
        end
      end

      module_function

      # Registers a persistence plugin; a plugin's own file calls this when it is required.
      #
      # @param name [Symbol, String] the plugin's name, such as `:era`
      # @param plugin [Object] anything responding to `contribute_boot_gates(registry, gates)`
      # @return [Object] the plugin just registered
      def register_plugin(name, plugin) = Plugin.register(name, plugin)

      # Whether the named persistence plugin is loaded in this process.
      #
      # @return [Boolean]
      def plugin?(name) = Plugin.registered?(name)

      # Yields every loaded persistence plugin, in registration order.
      def each_plugin(&) = Plugin.each(&)

      # Whether any persistence plugin is loaded in this process.
      #
      # @return [Boolean]
      def plugins_loaded? = Plugin.any?
    end
  end
end
