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
            port.broadcast_event({
              event: "ServerError", aggregate: "Server",
              data: { message: args[:message], source: "browser", timestamp: args[:timestamp] }
            })
          elsif msg && msg[:type] == "command" && msg[:command] == "StateSnapshot"
            args = msg[:args] || {}
            buffer.save_snapshot(args[:state], args[:captured_at])
          elsif msg && msg[:type] == "command" && msg[:command] == "TestResult"
            args = msg[:args] || {}
            icon = args[:status] == "passed" ? "\e[32m.\e[0m" : "\e[31mF\e[0m"
            print icon
            if args[:status] != "passed" && args[:command] != "SUMMARY"
              $stderr.puts "\n  \e[31m#{args[:command]}: #{args[:reason]}\e[0m"
            end
            if args[:command] == "SUMMARY"
              puts "\n  #{args[:event]} tests #{args[:status]}"
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
          var dot = null;

          function createDot() {
            dot = document.createElement("div");
            dot.style.cssText = "position:fixed;bottom:8px;right:8px;width:8px;height:8px;" +
              "border-radius:50%;background:#22c55e;opacity:0;transition:opacity 0.3s;" +
              "pointer-events:none;z-index:9999";
            document.body.appendChild(dot);
          }

          function flashDot() {
            if (!dot) return;
            dot.style.opacity = "1";
            setTimeout(function() { dot.style.opacity = "0"; }, 400);
          }

          function capture() {
            if (!capturing) return;
            try {
              var state = {};
              if (window.HecksApp) {
                var s = window.HecksApp.state;
                state = {
                  tab: s.layout.activeTab,
                  sidebar: s.layout.sidebarCollapsed ? "collapsed" : "open",
                  events: s.events.length,
                  projects: s.projects.length
                };
              }
              if (window.HecksIDE && window.HecksIDE.raw) {
                window.HecksIDE.raw(JSON.stringify({
                  type: "command", aggregate: "Debug", command: "StateSnapshot",
                  args: { state: JSON.stringify(state), captured_at: new Date().toISOString() }
                }));
              }
              flashDot();
            } catch(e) {}
          }

          function start() {
            capturing = true;
            if (!dot) createDot();
            timer = setInterval(capture, interval);
          }
          function stop() { capturing = false; if (timer) clearInterval(timer); }

          if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", function() { setTimeout(start, 2000); });
          else setTimeout(start, 2000);

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
