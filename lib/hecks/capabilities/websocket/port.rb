# Hecks::Capabilities::Websocket::Port
#
# Runtime-facing WebSocket port. Dispatches incoming commands
# through the command bus and broadcasts domain events to all
# connected clients. Transport-agnostic — the actual WS library
# is provided by a swappable adapter.
#
#   port = Websocket::Port.new(runtime)
#   port.handle_open(client)
#   port.handle_message(client, '{"type":"command",...}')
#   port.broadcast_event(domain_event)
#
require "json"

module Hecks
  module Capabilities
    module Websocket
      # Hecks::Capabilities::Websocket::Port
      #
      # Transport-agnostic WebSocket port for the runtime command/event buses.
      #
      class Port
        attr_reader :clients

        def initialize(runtime)
          @runtime = runtime
          @clients = []
          @on_connect_hooks = []
        end

        # Register a hook called when a new client connects.
        #
        # @yield [client] called with the new connection
        def on_connect(&block)
          @on_connect_hooks << block
        end

        # A client connected.
        #
        # @param client [Object] must respond to #send(string)
        def handle_open(client)
          @clients << client
          @on_connect_hooks.each { |hook| hook.call(client) }
        end

        # A client disconnected.
        #
        # @param client [Object]
        def handle_close(client)
          @clients.delete(client)
        end

        # Parse and dispatch an incoming command frame.
        #
        # @param client [Object] the sending connection
        # @param raw [String] raw JSON string
        def handle_message(client, raw)
          msg = JSON.parse(raw, symbolize_names: true)
          return unless msg[:type] == "command"

          command_name = msg[:command].to_s
          args = (msg[:args] || {}).transform_keys(&:to_sym)
          @runtime.command_bus.dispatch(command_name, **args)
        rescue JSON::ParserError
          send_json(client, { type: "error", message: "Invalid JSON" })
        rescue => e
          send_json(client, { type: "error", message: "#{command_name}: #{e.message}" })
        end

        # Push a domain event to all connected clients.
        #
        # @param event [Object] a domain event instance
        def broadcast_event(event)
          event_name = Hecks::Utils.const_short_name(event)
          agg_name = infer_aggregate(event)
          payload = JSON.generate({
            type: "event",
            event: event_name,
            aggregate: agg_name,
            data: event_to_hash(event)
          })
          @clients.each { |c| c.send(payload) rescue nil }
        end

        # Send a JSON message to a single client.
        #
        # @param client [Object]
        # @param hash [Hash]
        def send_json(client, hash)
          client.send(JSON.generate(hash))
        rescue
        end

        private

        def event_to_hash(event)
          return event.to_h if event.respond_to?(:to_h)
          event.instance_variables.each_with_object({}) do |ivar, h|
            h[ivar.to_s.delete_prefix("@")] = event.instance_variable_get(ivar)
          end
        end

        def infer_aggregate(event)
          parts = event.class.name.to_s.split("::")
          parts.length >= 3 ? parts[-3] : parts.first
        end
      end
    end
  end
end
