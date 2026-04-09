# Hecks::Capabilities::Websocket::Port
#
# Runtime-facing WebSocket port. Dispatches incoming commands
# through the command bus and broadcasts domain events to all
# connected clients. Supports multi-runtime dispatch — commands
# can target project runtimes by including a "project" field.
#
#   port = Websocket::Port.new(runtime)
#   port.add_runtime("pizzas", pizzas_runtime)
#   port.handle_message(client, '{"type":"command","project":"pizzas",...}')
#
require "json"

module Hecks
  module Capabilities
    module Websocket
      # Hecks::Capabilities::Websocket::Port
      #
      # Multi-runtime WebSocket port for command dispatch and event broadcast.
      #
      class Port
        attr_reader :clients

        def initialize(runtime)
          @runtime = runtime
          @project_runtimes = {}
          @clients = []
          @on_connect_hooks = []
        end

        # Register a project runtime for play-mode dispatch.
        #
        # @param name [String] project name
        # @param runtime [Hecks::Runtime] the booted runtime
        def add_runtime(name, runtime)
          @project_runtimes[name] = runtime
          runtime.event_bus.on_any { |event| broadcast_event(event, project: name) }
        end

        def on_connect(&block)
          @on_connect_hooks << block
        end

        def handle_open(client)
          @clients << client
          @on_connect_hooks.each { |hook| hook.call(client) }
        end

        def handle_close(client)
          @clients.delete(client)
        end

        # Parse and dispatch an incoming command frame.
        # If "project" is set, dispatch to that project's runtime.
        # Otherwise dispatch to the IDE runtime.
        #
        # Commands may include a +meta+ hash. When +meta.no_respond+ is
        # true, the sending client is excluded from the resulting event
        # broadcast — the command still executes for domain history.
        def handle_message(client, raw)
          msg = JSON.parse(raw, symbolize_names: true)
          return unless msg[:type] == "command"

          command_name = msg[:command].to_s
          args = (msg[:args] || {}).transform_keys(&:to_sym)
          meta = msg[:meta] || {}
          project = msg[:project]&.to_s

          Thread.current[:_hecks_ws_suppress_client] = client if meta[:no_respond]

          if project && @project_runtimes[project]
            @project_runtimes[project].command_bus.dispatch(command_name, **args)
          else
            @runtime.command_bus.dispatch(command_name, **args)
          end
        rescue JSON::ParserError
          send_json(client, { type: "error", message: "Invalid JSON" })
        rescue => e
          send_json(client, { type: "error", message: "#{command_name}: #{e.message}" })
        ensure
          Thread.current[:_hecks_ws_suppress_client] = nil
        end

        # Push a domain event to all connected clients.
        # Skips the sending client when the command carried +no_respond+ meta.
        def broadcast_event(event, project: nil)
          event_name = Hecks::Utils.const_short_name(event)
          agg_name = infer_aggregate(event)
          payload = JSON.generate({
            type: "event",
            event: event_name,
            aggregate: agg_name,
            project: project,
            data: event_to_hash(event)
          })
          suppress = Thread.current[:_hecks_ws_suppress_client]
          @clients.each { |c| c.send(payload) rescue nil unless c == suppress }
        end

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
