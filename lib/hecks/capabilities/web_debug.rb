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
          elsif msg && msg[:type] == "command" && msg[:command] == "ConsoleError"
            args = msg[:args] || {}
            $stderr.puts "[Browser] #{args[:message]}"
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

        adapter.mount("/hecks/screenshots") do |_req, res|
          res["Content-Type"] = "application/json"
          res.body = JSON.generate({ count: buffer.count, latest: buffer.latest })
        end

        js = CLIENT_JS
        adapter.mount("/hecks/debug.js") do |_req, res|
          res["Content-Type"] = "application/javascript"
          res.body = js
        end
      end
      private_class_method :mount_routes

      CLIENT_JS = <<~JS
        (function() {
          "use strict";
          var capturing = true, interval = 1000, timer = null;

          function capture() {
            if (!capturing || !window.html2canvas) return;
            var el = document.getElementById("ide") || document.body;
            html2canvas(el, { scale: 0.5, logging: false, useCORS: true }).then(function(canvas) {
              var data = canvas.toDataURL("image/jpeg", 0.6).split(",")[1];
              if (data && window.HecksIDE && window.HecksIDE.raw) {
                window.HecksIDE.raw(JSON.stringify({
                  type: "command", aggregate: "Screenshot", command: "CaptureFrame",
                  args: { frame_data: data, captured_at: new Date().toISOString() }
                }));
              }
            }).catch(function() {});
          }

          function start() { capturing = true; timer = setInterval(capture, interval); }
          function stop() { capturing = false; if (timer) clearInterval(timer); }

          if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", function() { setTimeout(start, 2000); });
          else setTimeout(start, 2000);

          // Stream console errors to server
          var origError = console.error;
          console.error = function() {
            origError.apply(console, arguments);
            var msg = Array.prototype.slice.call(arguments).map(String).join(" ");
            if (window.HecksIDE && window.HecksIDE.raw) {
              window.HecksIDE.raw(JSON.stringify({
                type: "command", aggregate: "Debug", command: "ConsoleError",
                args: { message: msg, timestamp: new Date().toISOString() }
              }));
            }
          };

          // Catch unhandled errors
          window.addEventListener("error", function(e) {
            if (window.HecksIDE && window.HecksIDE.raw) {
              window.HecksIDE.raw(JSON.stringify({
                type: "command", aggregate: "Debug", command: "ConsoleError",
                args: { message: e.message + " at " + e.filename + ":" + e.lineno, timestamp: new Date().toISOString() }
              }));
            }
          });

          window.HecksDebug = { capture: capture, start: start, stop: stop };
        })();
      JS
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
