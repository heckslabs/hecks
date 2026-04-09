# Hecks::Capabilities::AcceptanceTest::TestOverlay
#
# @domain AcceptanceTest
#
# Generates the floating overlay UI and result rendering JS for the
# acceptance test runner. Purely visual — no domain logic.
#
#   overlay = TestOverlay.new
#   overlay.generate  # => JS string for overlay + result rendering
#
module Hecks
  module Capabilities
    module AcceptanceTest
      class TestOverlay
        def generate
          [show_overlay, show_helpers, append_helpers].join("\n")
        end

        private

        def show_overlay
          <<~JS

              function showOverlay() {
                var old = document.getElementById("hecks-test-overlay");
                if (old) old.remove();
                var el = document.createElement("div");
                el.id = "hecks-test-overlay";
                el.style.cssText = "position:fixed;bottom:0;right:0;width:420px;max-height:60vh;overflow:auto;background:#0d0d0d;border:1px solid rgba(255,255,255,0.12);border-radius:8px 0 0 0;z-index:9999;padding:12px;font-size:12px;";
                el.innerHTML = '<div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:8px"><span id="hecks-test-overlay-title" style="color:#4361ee;font-weight:600">Running Tests</span><button onclick="this.parentElement.parentElement.remove()" style="color:#666;cursor:pointer;background:none;border:none">&times;</button></div><div id="hecks-test-overlay-running" style="color:#4361ee;font-family:monospace;margin-bottom:4px"></div><div id="hecks-test-overlay-bar" style="width:100%;background:rgba(255,255,255,0.08);border-radius:4px;height:4px;margin-bottom:8px"><div id="hecks-test-overlay-fill" style="height:4px;border-radius:4px;background:#4361ee;width:0;transition:width 0.1s"></div></div><div id="hecks-test-overlay-results"></div>';
                document.body.appendChild(el);
              }
          JS
        end

        def show_helpers
          <<~JS

              function showRunning(name) {
                var el = document.getElementById("hecks-test-overlay-running");
                if (el) el.textContent = name ? "\\u25b6 " + name : "";
              }

              function showProgress(n, total) {
                var fill = document.getElementById("hecks-test-overlay-fill");
                if (fill) fill.style.width = (total > 0 ? n/total*100 : 0) + "%";
              }
          JS
        end

        def append_helpers
          <<~JS

              function appendGroupHeader(group) {
                var html = '<div style="color:#4361ee;font-weight:600;font-size:11px;margin-top:8px;margin-bottom:4px;border-top:1px solid rgba(255,255,255,0.08);padding-top:6px">' + group + '</div>';
                var c = document.getElementById("hecks-test-overlay-results");
                if (c) c.insertAdjacentHTML("beforeend", html);
                var p = document.getElementById("test-results");
                if (p) p.insertAdjacentHTML("beforeend", html);
              }

              function appendResult(r) {
                var icon = r.status === "passed" ? "\\u2705" : "\\u274c";
                var color = r.status === "passed" ? "#22c55e" : "#ef4444";
                var evt = r.event ? " \\u2192 " + r.event : "";
                var fail = r.reason ? ' <span style="color:#ef4444;font-size:10px">(' + r.reason + ')</span>' : "";
                var html = '<div style="display:flex;align-items:center;gap:6px;padding:1px 0;color:'+color+'"><span>'+icon+'</span><span style="font-family:monospace;font-size:11px">'+r.command+'</span><span style="color:#555;font-size:10px">'+evt+'</span>'+fail+'</div>';
                var c = document.getElementById("hecks-test-overlay-results");
                if (c) { c.insertAdjacentHTML("beforeend", html); c.scrollTop = c.scrollHeight; }
                var p = document.getElementById("test-results");
                if (p) { p.insertAdjacentHTML("beforeend", html); p.scrollTop = p.scrollHeight; }
              }
          JS
        end
      end
    end
  end
end
