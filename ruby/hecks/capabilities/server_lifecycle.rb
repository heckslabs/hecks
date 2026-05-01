# Hecks::Capabilities::ServerLifecycle
#
# @domain Server.Start, Server.Stop
#
# Capability for managing the IDE server lifecycle from the web UI.
# Wires Start and Stop commands through the WebSocket so the user
# can shut down the server from the browser.
#
#   dispatch("Server", "Stop", {})  // from browser JS
#
require_relative "dsl"

module Hecks
  module Capabilities
    module ServerLifecycle
      # Wire the Server aggregate commands to actual server control.
      #
      # @param runtime [Hecks::Runtime]
      def self.apply(runtime)
        wire_websocket(runtime)
        puts "  \e[32m✓\e[0m server_lifecycle"
      end

      def self.wire_websocket(runtime)
        return unless runtime.respond_to?(:websocket)
        port = runtime.websocket
        original = port.method(:handle_message)

        port.define_singleton_method(:handle_message) do |client, raw|
          msg = JSON.parse(raw, symbolize_names: true) rescue nil
          if msg && msg[:type] == "command" && msg[:aggregate] == "Server"
            ServerLifecycle.handle(port, client, msg[:command], msg[:args] || {})
          else
            original.call(client, raw)
          end
        end
      end

      def self.handle(port, client, cmd, args)
        case cmd
        when "Stop"
          port.broadcast_event({ event: "ServerStopped", aggregate: "Server", data: {} })
          Thread.new { sleep 0.5; exit(0) }
        when "Start"
          # Already running — acknowledge
          port.send_json(client, { type: "event", event: "ServerStarted", aggregate: "Server", data: args })
        end
      end

      private_class_method :wire_websocket
    end
  end
end

Hecks.capability :server_lifecycle do
  description "Server start/stop control from the web UI"
  direction :driving
  on_apply do |runtime|
    Hecks::Capabilities::ServerLifecycle.apply(runtime)
  end
end
