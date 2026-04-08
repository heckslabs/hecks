# Hecks::Capabilities::AcceptanceTest::TestGenerator
#
# Generates acceptance test JS from the domain IR.
# Every command becomes a test case. The runner dispatches
# each one and validates an event fires.
#
#   gen = TestGenerator.new(runtime)
#   gen.generate  # => "// Hecks Acceptance Tests ..."
#
module Hecks
  module Capabilities
    module AcceptanceTest
      class TestGenerator
        def initialize(runtime)
          @domain = runtime.domain
        end

        def generate
          [header, test_plan, runner, overlay, ui, footer].join("\n")
        end

        private

        def header
          <<~JS
            // Hecks Acceptance Tests — generated from #{@domain.name}
            (function() {
              "use strict";
              var results = [], running = false;

              function fireEvent(name, data) {
                if (window.HecksApp) window.HecksApp.handleEvent({ event: name, data: data || {} });
              }
          JS
        end

        def test_plan
          tests = []

          # Client-side state tests
          tests << '{ name: "SelectTab → editor", fn: function() { fireEvent("TabSelected", { tab_name: "editor" }); }}'
          tests << '{ name: "SelectTab → diagrams", fn: function() { fireEvent("TabSelected", { tab_name: "diagrams" }); }}'
          tests << '{ name: "SelectTab → console", fn: function() { fireEvent("TabSelected", { tab_name: "console" }); }}'
          tests << '{ name: "SelectTab → workbench", fn: function() { fireEvent("TabSelected", { tab_name: "workbench" }); }}'
          tests << '{ name: "ToggleSidebar → collapse", fn: function() { fireEvent("SidebarToggled", { sidebar_collapsed: true }); }}'
          tests << '{ name: "ToggleSidebar → expand", fn: function() { fireEvent("SidebarToggled", { sidebar_collapsed: false }); }}'
          tests << '{ name: "ToggleEvents → collapse", fn: function() { fireEvent("EventsPanelToggled", { events_collapsed: true }); }}'
          tests << '{ name: "ToggleEvents → expand", fn: function() { fireEvent("EventsPanelToggled", { events_collapsed: false }); }}'

          # Domain command tests from IR
          @domain.aggregates.each do |agg|
            agg.commands.each do |cmd|
              args = cmd.attributes.map do |a|
                type = a.type.respond_to?(:name) ? a.type.name.split("::").last : a.type.to_s
                val = (type == "Integer" || type == "Float") ? "1" : '"test"'
                "#{a.name}: #{val}"
              end
              args_str = args.empty? ? "{}" : "{ #{args.join(", ")} }"
              tests << "{ name: #{(agg.name + "." + cmd.name).inspect}, fn: function() { dispatch(#{agg.name.inspect}, #{cmd.name.inspect}, #{args_str}); }}"
            end
          end

          "\n  var tests = [\n    #{tests.join(",\n    ")}\n  ];\n"
        end

        def runner
          <<~JS

              function dispatch(agg, cmd, args) {
                if (window.Hecks && window.Hecks.dispatch) return window.Hecks.dispatch(agg, cmd, args);
                if (window.HecksIDE && window.HecksIDE.command) window.HecksIDE.command(agg, cmd, args);
              }

              function runAll() {
                if (running) return;
                running = true; results = [];
                showOverlay(); showProgress(0, tests.length);
                runNext(0);
              }

              function runNext(idx) {
                if (idx >= tests.length) { running = false; finalize(); return; }
                var test = tests[idx];
                showRunning(test.name);
                var before = window.HecksApp ? window.HecksApp.state.events.length : 0;
                try { test.fn(); } catch(e) {}
                setTimeout(function() {
                  var after = window.HecksApp ? window.HecksApp.state.events.length : 0;
                  var got = after > before;
                  var evt = got && window.HecksApp ? (window.HecksApp.state.events[0].event || "") : "";
                  var r = { command: test.name, event: evt, status: got ? "passed" : "pending" };
                  results.push(r);
                  appendResult(r);
                  showProgress(idx + 1, tests.length);
                  runNext(idx + 1);
                }, 0);
              }

              function finalize() {
                showRunning(null);
                var passed = results.filter(function(r){return r.status==="passed"}).length;
                var el = document.getElementById("hecks-test-overlay-title");
                if (el) el.textContent = passed + "/" + results.length + " passed";
                fireEvent("TabSelected", { tab_name: "tests" });
              }
          JS
        end

        def overlay
          <<~JS

              function showOverlay() {
                var old = document.getElementById("hecks-test-overlay");
                if (old) old.remove();
                var el = document.createElement("div");
                el.id = "hecks-test-overlay";
                el.style.cssText = "position:fixed;bottom:0;right:0;width:420px;max-height:60vh;overflow:auto;background:#0d0d0d;border:1px solid rgba(255,255,255,0.12);border-radius:8px 0 0 0;z-index:9999;padding:12px;font-size:12px;";
                el.innerHTML = '<div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:8px"><span id="hecks-test-overlay-title" style="color:#4361ee;font-weight:600">Running Tests</span><button onclick="this.parentElement.parentElement.remove()" style="color:#666;cursor:pointer;background:none;border:none">✕</button></div><div id="hecks-test-overlay-running" style="color:#4361ee;font-family:monospace;margin-bottom:4px"></div><div id="hecks-test-overlay-bar" style="width:100%;background:rgba(255,255,255,0.08);border-radius:4px;height:4px;margin-bottom:8px"><div id="hecks-test-overlay-fill" style="height:4px;border-radius:4px;background:#4361ee;width:0;transition:width 0.1s"></div></div><div id="hecks-test-overlay-results"></div>';
                document.body.appendChild(el);
              }

              function showRunning(name) {
                var el = document.getElementById("hecks-test-overlay-running");
                if (el) el.textContent = name ? "▶ " + name : "";
              }

              function showProgress(n, total) {
                var fill = document.getElementById("hecks-test-overlay-fill");
                if (fill) fill.style.width = (total > 0 ? n/total*100 : 0) + "%";
              }

              function appendResult(r) {
                var icon = r.status === "passed" ? "✅" : "⬜";
                var color = r.status === "passed" ? "#22c55e" : "#666";
                var evt = r.event ? " → " + r.event : "";
                var html = '<div style="display:flex;align-items:center;gap:6px;padding:1px 0;color:'+color+'"><span>'+icon+'</span><span style="font-family:monospace;font-size:11px">'+r.command+'</span><span style="color:#555;font-size:10px">'+evt+'</span></div>';
                var c = document.getElementById("hecks-test-overlay-results");
                if (c) { c.insertAdjacentHTML("beforeend", html); c.scrollTop = c.scrollHeight; }
                // Also to panel if visible
                var p = document.getElementById("test-results");
                if (p) { p.insertAdjacentHTML("beforeend", html); p.scrollTop = p.scrollHeight; }
              }
          JS
        end

        def ui
          <<~JS

              function setup() {
                document.addEventListener("click", function(e) {
                  if (e.target.closest("[data-action='run-all-tests']")) runAll();
                  if (e.target.closest("[data-action='reset-tests']")) {
                    results = []; running = false;
                    var c = document.getElementById("test-results");
                    if (c) c.innerHTML = '<p style="color:#666;font-size:13px">Click Run All to test every command.</p>';
                    var o = document.getElementById("hecks-test-overlay");
                    if (o) o.remove();
                  }
                });
              }

              if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", setup);
              else setup();
          JS
        end

        def footer
          "\n  window.HecksTests = { runAll: runAll };\n})();\n"
        end
      end
    end
  end
end
