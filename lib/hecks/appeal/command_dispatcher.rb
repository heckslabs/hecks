# Hecks::Appeal::CommandDispatcher
#
# Receives command messages from WebSocket clients, routes them to
# DomainBridge methods, and emits events back over the socket.
# Handler modules are mixed in from command_dispatcher/ subdirectory.
#
#   dispatcher = Hecks::Appeal::CommandDispatcher.new(bridge)
#   dispatcher.on_open(ws)
#   dispatcher.on_message(ws, '{"type":"command","aggregate":"Project","command":"OpenProject","args":{"path":"."}}')
#
require "json"
require_relative "layout_state"
require_relative "screenshot_buffer"
require_relative "command_dispatcher/project_handlers"
require_relative "command_dispatcher/layout_handlers"
require_relative "command_dispatcher/explorer_handlers"

module Hecks
  module Appeal
    class CommandDispatcher
      include ProjectHandlers
      include LayoutHandlers
      include ExplorerHandlers

      def initialize(bridge)
        @bridge = bridge
        @clients = []
        @client_state = {}
        @screenshots = ScreenshotBuffer.new
      end

      def on_open(ws)
        @clients << ws
        @client_state[ws.object_id] = LayoutState.new
        dispatch(ws, "Layout", "RestoreState", {})
        push_state(ws)
        handle_diagram_generate_overview(ws, {})
      end

      def on_close(ws)
        dispatch(ws, "Layout", "SaveState", {})
        @clients.delete(ws)
        @client_state.delete(ws.object_id)
        @agent_histories&.delete(ws.object_id)
      end

      def on_message(ws, raw)
        msg = JSON.parse(raw, symbolize_names: true)
        return unless msg[:type] == "command"
        dispatch(ws, msg[:aggregate].to_s, msg[:command].to_s, msg[:args] || {})
      rescue JSON::ParserError
      rescue => e
        $stderr.puts "[Dispatch] #{e.class}: #{e.message}"
        $stderr.flush
      end

      private

      def dispatch(ws, aggregate, command, args)
        handler = "handle_#{underscore(aggregate)}_#{underscore(command)}"
        send(handler, ws, args) if respond_to?(handler, true)
      end

      def push_state(ws)
        send_json(ws, { type: "state", data: @bridge.to_state.merge(layout: layout(ws).to_h, cwd: Dir.pwd) })
      end

      def emit(ws, event, aggregate, data = {})
        send_json(ws, { type: "event", event: event, aggregate: aggregate, data: data })
        fire_policies(ws, event, data) unless @firing_policies
      end

      def layout(ws) = @client_state[ws.object_id]

      def broadcast_event(event, aggregate, data)
        @clients.each do |ws|
          next if layout(ws)&.to_h&.dig(:stream_paused)
          emit(ws, event, aggregate, data)
        end
      end


      def fire_policies(ws, event_name, data)
        domains = @bridge.all_domains.map { |d| d[:domain] }.compact
        return if domains.empty?
        @firing_policies = true
        domains.each do |domain|
          domain.policies.select(&:reactive?).each do |policy|
            next unless policy.event_name == event_name
            args = policy.defaults.dup
            policy.attribute_map.each { |from, to| args[to] = data[from] }
            agg = find_aggregate_for_command(policy.trigger_command)
            $stderr.puts "[Policy] #{policy.name}: #{event_name} -> #{policy.trigger_command} agg=#{agg&.name} args=#{args.inspect}"
            $stderr.flush
            dispatch(ws, agg&.name || "Unknown", policy.trigger_command, args)
          end
        end
      ensure
        @firing_policies = false
      end

      def find_aggregate_for_command(command_name)
        @bridge.all_domains.map { |d| d[:domain] }.compact.each do |domain|
          agg = domain.aggregates.find { |a| a.commands.any? { |c| c.name == command_name } }
          return agg if agg
        end
        nil
      end

      def find_project_for_file(path)
        abs = File.expand_path(path)
        @bridge.projects.values.find do |p|
          (p[:files] || []).any? { |f| f[:path] == path || f[:path] == abs }
        end
      end

      def underscore(str)
        str.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2').gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
      end

      def send_json(ws, data)
        ws.send(JSON.generate(data))
      rescue
      end
    end
  end
end
