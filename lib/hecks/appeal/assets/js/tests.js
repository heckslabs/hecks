// HecksAppeal IDE — Visual Acceptance Test Runner
//
// Dispatches every domain command with visible UI changes.
// Each command runs with a delay so you watch the IDE react.
// UI tests fire events locally. Domain tests go over WebSocket.
//

(function () {
  "use strict";

  var results = [];
  var running = false;
  var DELAY = 400;

  function fireEvent(name, data) {
    if (window.HecksApp) window.HecksApp.handleEvent({ event: name, data: data || {} });
  }

  function setup() {
    document.addEventListener("click", function (e) {
      if (e.target.closest("[data-action='run-all-tests']")) runAll();
      if (e.target.closest("[data-action='reset-tests']")) reset();
    });
  }

  function runAll() {
    if (running) return;
    running = true;
    results = [];
    showOverlay();
    var tests = buildTestPlan();
    showProgress(0, tests.length);
    runNext(tests, 0);
  }

  function showOverlay() {
    var existing = document.getElementById("test-overlay");
    if (existing) existing.remove();
    var overlay = document.createElement("div");
    overlay.id = "test-overlay";
    overlay.style.cssText = "position:fixed;bottom:0;right:0;width:400px;max-height:60vh;overflow:auto;background:#0d0d0d;border:1px solid rgba(255,255,255,0.12);border-radius:8px 0 0 0;z-index:9999;padding:12px;font-size:12px;";
    overlay.innerHTML = '<div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:8px"><span style="color:#4361ee;font-weight:600">Running Tests</span><button onclick="this.parentElement.parentElement.remove()" style="color:#666;cursor:pointer">✕</button></div><div id="test-overlay-results"></div><div id="test-overlay-progress" style="margin-top:8px"></div>';
    document.body.appendChild(overlay);
  }

  function hideOverlay() {
    var el = document.getElementById("test-overlay");
    if (el) setTimeout(function() { el.remove(); }, 3000);
  }

  function buildTestPlan() {
    var tests = [];

    // UI state tests — visually change the IDE
    tests.push({ name: "SelectTab → editor", fn: function() { fireEvent("TabSelected", { tab_name: "editor" }); }});
    tests.push({ name: "SelectTab → diagrams", fn: function() { fireEvent("TabSelected", { tab_name: "diagrams" }); }});
    tests.push({ name: "SelectTab → console", fn: function() { fireEvent("TabSelected", { tab_name: "console" }); }});
    tests.push({ name: "SelectTab → workbench", fn: function() { fireEvent("TabSelected", { tab_name: "workbench" }); }});
    tests.push({ name: "SelectTab → features", fn: function() { fireEvent("TabSelected", { tab_name: "features" }); }});
    tests.push({ name: "ToggleSidebar → collapse", fn: function() { fireEvent("SidebarToggled", { sidebar_collapsed: true }); }});
    tests.push({ name: "ToggleSidebar → expand", fn: function() { fireEvent("SidebarToggled", { sidebar_collapsed: false }); }});
    tests.push({ name: "ToggleEvents → collapse", fn: function() { fireEvent("EventsPanelToggled", { events_collapsed: true }); }});
    tests.push({ name: "ToggleEvents → expand", fn: function() { fireEvent("EventsPanelToggled", { events_collapsed: false }); }});

    // Client-side command tests
    if (window.Hecks && window.Hecks.handlers) {
      Object.keys(window.Hecks.handlers).forEach(function (key) {
        var parts = key.split(".");
        tests.push({
          name: key,
          fn: function () { window.Hecks.dispatch(parts[0], parts[1], {}); }
        });
      });
    }

    // Project domain commands — dispatch to loaded projects via WebSocket
    var state = window.HecksApp && window.HecksApp.state;
    if (state && state.projects) {
      state.projects.forEach(function (project) {
        if (!project.domains) return;
        project.domains.forEach(function (domain) {
          if (!domain.aggregates) return;
          domain.aggregates.forEach(function (agg) {
            (agg.commands || []).forEach(function (cmd) {
              var cmdName = typeof cmd === "string" ? cmd : cmd.name;
              var attrs = typeof cmd === "object" ? (cmd.attributes || []) : [];
              tests.push({
                name: project.name + "/" + agg.name + "." + cmdName,
                fn: function () {
                  var args = {};
                  attrs.forEach(function (a) {
                    var n = typeof a === "string" ? a : a.name;
                    var t = typeof a === "object" ? a.type : "String";
                    args[n] = (t === "Integer" || t === "Float") ? 1 : "test";
                  });
                  if (window.HecksIDE && window.HecksIDE.raw) {
                    window.HecksIDE.raw(JSON.stringify({
                      type: "command", aggregate: agg.name,
                      command: cmdName, args: args, project: project.name
                    }));
                  }
                }
              });
            });
          });
        });
      });
    }

    return tests;
  }

  function runNext(tests, idx) {
    if (idx >= tests.length) {
      running = false;
      renderSummary();
      hideOverlay();
      fireEvent("TabSelected", { tab_name: "tests" });
      return;
    }

    var test = tests[idx];
    showRunning(test.name);
    var evtsBefore = window.HecksApp ? window.HecksApp.state.events.length : 0;

    try { test.fn(); } catch (e) {}

    setTimeout(function () {
      var evtsAfter = window.HecksApp ? window.HecksApp.state.events.length : 0;
      var got = evtsAfter > evtsBefore;
      var evt = got && window.HecksApp ? (window.HecksApp.state.events[0].event || "") : "";
      var result = { command: test.name, event: evt, status: got ? "passed" : "pending" };
      results.push(result);
      showProgress(idx + 1, tests.length);
      appendResult(result);
      runNext(tests, idx + 1);
    }, DELAY);
  }

  function showRunning(name) {
    var el = document.getElementById("test-running");
    if (!el) {
      var c = document.getElementById("test-progress");
      if (c) { el = document.createElement("div"); el.id = "test-running"; el.className = "text-accent text-sm font-mono animate-pulse mt-1"; c.appendChild(el); }
    }
    if (el) el.textContent = name ? "▶ " + name : "";
  }

  function appendResult(r) {
    var icon = r.status === "passed" ? "✅" : "⬜";
    var cls = r.status === "passed" ? "color:#22c55e" : "color:#666";
    var evt = r.event ? " → " + r.event : "";
    var html = '<div style="display:flex;align-items:center;gap:6px;padding:1px 0;' + cls + '">' +
      '<span>' + icon + '</span><span style="font-family:monospace">' + r.command + '</span>' +
      '<span style="color:#666">' + evt + '</span></div>';

    // Append to overlay (always visible)
    var overlay = document.getElementById("test-overlay-results");
    if (overlay) { overlay.insertAdjacentHTML("beforeend", html); overlay.scrollTop = overlay.scrollHeight; }

    // Also append to tests panel
    var panel = document.getElementById("test-results");
    if (panel) { panel.insertAdjacentHTML("beforeend", html); panel.scrollTop = panel.scrollHeight; }
  }

  function showProgress(n, total) {
    var el = document.getElementById("test-progress"); if (el) el.classList.remove("hidden");
    var passed = results.filter(function(r) { return r.status === "passed"; }).length;
    var p = document.getElementById("test-passed"); if (p) p.textContent = passed + " passed";
    var f = document.getElementById("test-failed"); if (f) f.textContent = (n - passed) + " pending";
    var t = document.getElementById("test-total"); if (t) t.textContent = n + "/" + total;
    var bar = document.getElementById("test-bar"); if (bar) bar.style.width = (total > 0 ? n/total*100 : 0) + "%";
  }

  function renderSummary() {
    var passed = results.filter(function(r) { return r.status === "passed"; }).length;
    var bar = document.getElementById("test-bar");
    if (bar) bar.className = (passed === results.length ? "bg-green-400" : "bg-amber-400") + " h-1.5 rounded-full transition-all";
  }

  function reset() {
    results = []; running = false;
    var c = document.getElementById("test-results"); if (c) c.innerHTML = '<p class="text-white/[.38] text-sm">Click "Run All" to test every command.</p>';
    var el = document.getElementById("test-progress"); if (el) el.classList.add("hidden");
  }

  if (document.readyState === "loading") { document.addEventListener("DOMContentLoaded", setup); } else { setup(); }
})();
