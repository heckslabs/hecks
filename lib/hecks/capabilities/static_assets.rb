# Hecks::Capabilities::StaticAssets
#
# Static file serving capability. Serves HTML layouts, CSS, JS,
# and image assets over HTTP. Uses the same port+adapter pattern
# as the websocket capability — the port handles file lookup and
# content-type resolution, while the adapter provides the HTTP
# transport layer.
#
# Applied via hecksagon:
#   Hecks.hecksagon "MyApp" do
#     capabilities :static_assets
#   end
#
# World config:
#   Hecks.world "MyApp" do
#     static_assets do
#       port 4567
#       views "views"
#       assets "assets"
#     end
#   end
#
require_relative "dsl"
require_relative "static_assets/port"
require_relative "static_assets/adapter"

module Hecks
  module Capabilities
    # Hecks::Capabilities::StaticAssets
    #
    # Static asset serving capability — bridges HTTP transport to file lookup port.
    #
    module StaticAssets
      # Apply the StaticAssets capability to a runtime.
      # Reads config from the world file's static_assets block, creates the
      # port + adapter, and exposes them on the runtime.
      #
      # @param runtime [Hecks::Runtime] the booted runtime
      # @return [Hecks::Capabilities::StaticAssets::Port]
      def self.apply(runtime)
        config = world_config(runtime)
        listen_port = config[:port] || 4567
        views_dir = config[:views] || "views"
        assets_dir = config[:assets] || "assets"

        base_dir = runtime.respond_to?(:root) ? runtime.root : Dir.pwd
        resolved_views = File.expand_path(views_dir, base_dir)
        resolved_assets = File.expand_path(assets_dir, base_dir)

        port = Port.new(
          views_dir: resolved_views,
          assets_dir: resolved_assets,
          listen_port: listen_port
        )
        adapter = Adapter.new(port)

        runtime.instance_variable_set(:@static_assets_port, port)
        runtime.instance_variable_set(:@static_assets_adapter, adapter)
        runtime.define_singleton_method(:static_assets) { @static_assets_port }
        runtime.define_singleton_method(:static_assets_adapter) { @static_assets_adapter }
        port
      end

      def self.world_config(runtime)
        world = Hecks.respond_to?(:last_world) ? Hecks.last_world : nil
        world ? world.config_for(:static_assets) : {}
      end
      private_class_method :world_config
    end
  end
end

Hecks.capability :static_assets do
  description "Serve HTML/CSS/JS from project directories"
  config do
    port 4567, desc: "HTTP listen port"
    views "views", desc: "Views directory"
    assets "assets", desc: "Assets directory"
  end
  on_apply do |runtime|
    Hecks::Capabilities::StaticAssets.apply(runtime)
  end
end
