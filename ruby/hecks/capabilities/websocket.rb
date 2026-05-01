# Hecks::Capabilities::Websocket
#
# WebSocket driving adapter capability. Accepts TCP connections,
# performs the WS handshake, dispatches incoming command frames
# through the runtime's command bus, and pushes emitted events
# back over the wire as JSON.
#
# Applied via hecksagon:
#   Hecks.hecksagon "MyApp" do
#     capabilities :websocket
#   end
#
# Wire protocol (client -> server):
#   { "type": "command", "aggregate": "Layout", "command": "ToggleSidebar", "args": {} }
#
# Wire protocol (server -> client):
#   { "type": "event", "event": "SidebarToggled", "aggregate": "Layout", "data": {...} }
#
require "json"
require_relative "dsl"
require_relative "websocket/port"
require_relative "websocket/adapter"

module Hecks
  module Capabilities
    # Hecks::Capabilities::Websocket
    #
    # WebSocket driving adapter — bridges WS transport to the runtime command/event ports.
    #
    module Websocket
      # Apply the WebSocket capability to a runtime.
      # Reads config from the world file's websocket block, creates the
      # port + adapter, and subscribes to all domain events.
      #
      # @param runtime [Hecks::Runtime] the booted runtime
      # @return [Hecks::Capabilities::Websocket::Port]
      def self.apply(runtime)
        config = world_config(runtime)
        port = Port.new(runtime)
        listen_port = config[:port] || 4568
        adapter = Adapter.new(port, listen_port: listen_port)

        runtime.event_bus.on_any { |event| port.broadcast_event(event) }
        runtime.instance_variable_set(:@websocket_port, port)
        runtime.instance_variable_set(:@websocket_adapter, adapter)
        runtime.define_singleton_method(:websocket) { @websocket_port }
        runtime.define_singleton_method(:websocket_adapter) { @websocket_adapter }
        port
      end

      def self.world_config(runtime)
        world = Hecks.respond_to?(:last_world) ? Hecks.last_world : nil
        world ? world.config_for(:websocket) : {}
      end
      private_class_method :world_config
    end
  end
end

Hecks.capability :websocket do
  description "Bidirectional WebSocket command/event bridge"
  direction :driving
  config do
    port 4568, desc: "WebSocket listen port"
  end
  on_apply do |runtime|
    Hecks::Capabilities::Websocket.apply(runtime)
  end
end
