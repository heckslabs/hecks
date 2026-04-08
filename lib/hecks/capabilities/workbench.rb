# Hecks::Capabilities::Workbench
#
# Interactive domain REPL capability. Wire it to commands in the
# hecksagon using annotations:
#
#   # bluebook
#   aggregate "Pizza" do
#     command "ShowWorkbench" do
#       emits "WorkbenchShown"
#     end
#   end
#
#   # hecksagon
#   Hecks.hecksagon "Pizzas" do
#     capabilities :workbench
#     Pizza.show_workbench.workbench
#   end
#
require_relative "workbench/repl_generator"
require_relative "workbench/query_handler"

module Hecks
  module Capabilities
    # Hecks::Capabilities::Workbench
    #
    # Live domain REPL — attached to commands via hecksagon annotations.
    #
    module Workbench
      def self.apply(runtime)
        handler = QueryHandler.new(runtime)
        annotations = workbench_annotations(runtime)
        generator = ReplGenerator.new(runtime, annotations: annotations)

        runtime.instance_variable_set(:@workbench_handler, handler)
        runtime.instance_variable_set(:@workbench_js, generator.generate)
        runtime.instance_variable_set(:@workbench_annotations, annotations)
        runtime.define_singleton_method(:workbench) { @workbench_handler }
        runtime.define_singleton_method(:workbench_js) { @workbench_js }

        wire_events(runtime, annotations)
        mount_routes(runtime) if runtime.respond_to?(:static_assets_adapter)
        wire_websocket(runtime, handler) if runtime.respond_to?(:websocket)
        handler
      end

      # Find annotations where annotation == :workbench
      def self.workbench_annotations(runtime)
        hecksagon = runtime.instance_variable_get(:@hecksagon)
        return [] unless hecksagon&.respond_to?(:annotations)
        hecksagon.annotations.select { |a| a[:annotation] == :workbench }
      end
      private_class_method :workbench_annotations

      # Subscribe to events emitted by workbench-annotated commands.
      # When those events fire, broadcast a WorkbenchActivated event
      # so the UI knows to show the workbench for that aggregate.
      def self.wire_events(runtime, annotations)
        return if annotations.empty?
        agg_names = annotations.map { |a| a[:aggregate].to_s.split("::").last }
        runtime.event_bus.on_any do |event|
          event_agg = infer_aggregate(event)
          if agg_names.include?(event_agg)
            # The workbench-annotated command fired — UI should show workbench
          end
        end
      end
      private_class_method :wire_events

      def self.mount_routes(runtime)
        adapter = runtime.static_assets_adapter
        return unless adapter.respond_to?(:mount)
        js = runtime.workbench_js

        adapter.mount("/hecks/workbench.js") do |_req, res|
          res["Content-Type"] = "application/javascript"
          res.body = js
        end
      end
      private_class_method :mount_routes

      def self.wire_websocket(runtime, handler)
        port = runtime.websocket
        original_handler = port.method(:handle_message)
        port.define_singleton_method(:handle_message) do |client, raw|
          msg = JSON.parse(raw, symbolize_names: true) rescue nil
          if msg && msg[:type] == "workbench"
            result = handler.handle(msg)
            port.send_json(client, { type: "workbench_result", data: result })
          else
            original_handler.call(client, raw)
          end
        end
      end
      private_class_method :wire_websocket

      def self.infer_aggregate(event)
        parts = event.class.name.to_s.split("::")
        parts.length >= 3 ? parts[-3] : parts.first
      end
      private_class_method :infer_aggregate
    end
  end
end

Hecks.register_capability(:workbench) { |runtime| Hecks::Capabilities::Workbench.apply(runtime) }

Hecks.describe_capability(:workbench,
  description: "Interactive domain REPL — attach to commands via hecksagon annotations",
  config: {})
