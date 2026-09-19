module Hecks
  module Ports
    # Reopened to hold the persistence-plugin registry (`Plugin`, below) and
    # its call surface (`register_plugin`/`plugin?`/`each_plugin`) — see ADR
    # 0033 and `Plugin`'s own header for the seam this fills.
    module Persistence
      # A tiny, real seam — ADR 0033. Core never names a persistence plugin;
      # a plugin makes itself known as a side effect of being `require`d, the
      # same way an adapter's own `.rb` file already registers itself
      # (`Runtime::Registry#add_adapter`) rather than core listing adapter
      # names anywhere. `register_plugin` is the entire contract a plugin
      # must satisfy: anything responding to `contribute_boot_gates(registry,
      # gates)` (a no-op is a valid implementation).
      #
      # This is deliberately not the same registry `Hecks::Projector` uses
      # (ADR 0027) or `Runtime::BootGates` (ADR 0031) — each of those is
      # scoped to its own seam (IR-in/artifact-out; per-boot phased gates).
      # A shared base is deferred until a third registry actually wants one.
      #
      # **Name-keyed, process-wide, not per-boot** — unlike `BootGates` (one
      # instance per `Loader.boot` call, because gate registration is
      # capability-conditional per registry), a persistence plugin is either
      # `require`d into this process or it isn't; there is no "this boot's
      # registry doesn't need it" case to isolate against, so a plain
      # module-level hash is the right shape here, not an instantiable class.
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

          # Reports whether a plugin of that name has been required into this process.
          #
          # @param name [Symbol, String] the plugin's name
          # @return [Boolean] true when a plugin is registered under `name`
          def registered?(name)
            @plugins.key?(name.to_sym)
          end

          # Yields every registered plugin, in registration order.
          #
          # @yieldparam plugin [Object] a registered plugin
          # @return [Hash{Symbol => Object}, Enumerator] the plugin table when a block is
          #   given, otherwise an Enumerator over the plugins
          def each(&)
            @plugins.each_value(&)
          end

          # Reports whether any persistence plugin is loaded at all.
          #
          # @return [Boolean] true when at least one plugin is registered
          def any? = !@plugins.empty?
        end
      end

      # `Ports::Persistence.plugin?(:era)` / `.each_plugin` — the ordinary
      # call surface; `Plugin.register`/`.registered?`/`.each` stay reachable
      # directly for a plugin's own file to call at require-time.
      module_function

      # Registers a persistence plugin; a plugin's own file calls this when it is required.
      #
      # @param name [Symbol, String] the plugin's name, such as `:era`
      # @param plugin [Object] anything responding to `contribute_boot_gates(registry, gates)`
      # @return [Object] the plugin just registered
      def register_plugin(name, plugin) = Plugin.register(name, plugin)

      # Reports whether the named persistence plugin is loaded in this process.
      #
      # @param name [Symbol, String] the plugin's name
      # @return [Boolean] true when a plugin is registered under `name`
      def plugin?(name) = Plugin.registered?(name)

      # Yields every loaded persistence plugin, in registration order.
      #
      # @yieldparam plugin [Object] a registered plugin
      # @return [Hash{Symbol => Object}, Enumerator] the plugin table when a block is given,
      #   otherwise an Enumerator over the plugins
      def each_plugin(&) = Plugin.each(&)

      # Reports whether any persistence plugin is loaded in this process.
      #
      # @return [Boolean] true when at least one plugin is registered
      def plugins_loaded? = Plugin.any?
    end
  end
end
