# Hecks::Capabilities::LiveReload
#
# Live-reload capability for the Hecks framework. Watches .bluebook and
# .hec files for changes, hot-reloads the domain IR, and publishes a
# BluebookReloaded event through the runtime's event bus. When paired
# with the :websocket capability, connected browser clients receive the
# reload event automatically and can refresh their state.
#
# Applied via hecksagon:
#   Hecks.hecksagon "MyApp" do
#     capabilities :live_reload
#   end
#
# World config:
#   Hecks.world "MyApp" do
#     live_reload do
#       watch_dirs ["hecks", "lib"]
#       debounce   0.5
#     end
#   end
#
require_relative "live_reload/watcher"

module Hecks
  module Capabilities
    # Hecks::Capabilities::LiveReload
    #
    # File-watching capability that reloads domain definitions on change.
    #
    module LiveReload
      # Apply the live-reload capability to a runtime.
      # Reads config from the world file's live_reload block, creates the
      # watcher, and exposes it as runtime.live_reload.
      #
      # @param runtime [Object] the booted Hecks runtime
      # @return [Hecks::Capabilities::LiveReload::Watcher]
      def self.apply(runtime)
        config     = world_config(runtime)
        watch_dirs = Array(config[:watch_dirs] || ["hecks"])
        debounce   = config[:debounce]   || 0.5

        watcher = Watcher.new(runtime, watch_dirs: watch_dirs, debounce: debounce)

        runtime.instance_variable_set(:@live_reload, watcher)
        runtime.define_singleton_method(:live_reload) { @live_reload }
        watcher
      end

      def self.world_config(runtime)
        world = Hecks.respond_to?(:last_world) ? Hecks.last_world : nil
        world ? world.config_for(:live_reload) : {}
      end
      private_class_method :world_config
    end
  end
end

Hecks.register_capability(:live_reload) { |runtime| Hecks::Capabilities::LiveReload.apply(runtime) }
