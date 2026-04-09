# Hecks::Capabilities::WebDebug
#
# Visual debugging capability — screenshot capture, event inspection,
# performance overlay. Serves a debug panel and screenshot buffer.
#
#   Hecks.hecksagon "MyApp" do
#     capabilities :web_debug
#   end
#
require_relative "dsl"
require_relative "web_debug/screenshot_buffer"

module Hecks
  module Capabilities
    module WebDebug
      def self.apply(runtime)
        buffer = ScreenshotBuffer.new
        runtime.instance_variable_set(:@screenshot_buffer, buffer)
        runtime.define_singleton_method(:screenshots) { @screenshot_buffer }

        wire_websocket(runtime, buffer)
        mount_routes(runtime) if runtime.respond_to?(:static_assets_adapter)
      end

      def self.wire_websocket(runtime, buffer)
        return unless runtime.respond_to?(:websocket)
        port = runtime.websocket
        original = port.method(:handle_message)
        port.define_singleton_method(:handle_message) do |client, raw|
          msg = JSON.parse(raw, symbolize_names: true) rescue nil
          if msg && msg[:type] == "command" && msg[:command] == "CaptureFrame"
            args = msg[:args] || {}
            if args[:frame_data]
              path = buffer.save(args[:frame_data], args[:captured_at])
              port.send_json(client, { type: "event", event: "FrameCaptured", aggregate: "Screenshot", data: { path: File.basename(path) } })
            end
          else
            original.call(client, raw)
          end
        end
      end
      private_class_method :wire_websocket

      def self.mount_routes(runtime)
        adapter = runtime.static_assets_adapter
        return unless adapter.respond_to?(:mount)
        buffer = runtime.screenshots

        adapter.mount("/hecks/screenshots") do |req, res|
          res["Content-Type"] = "application/json"
          res.body = JSON.generate({ count: buffer.count, latest: buffer.latest })
        end
      end
      private_class_method :mount_routes
    end
  end
end

Hecks.capability :web_debug do
  description "Visual debugging — screenshot capture, event inspection"
  direction :driving
  on_apply do |runtime|
    Hecks::Capabilities::WebDebug.apply(runtime)
  end
end
