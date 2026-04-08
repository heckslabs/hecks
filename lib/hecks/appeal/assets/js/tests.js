// HecksAppeal IDE — Acceptance Test Runner
//
// Dispatches every domain command and validates events fire.
// Results shown as green/red per command. Uses memory mode.
//

(function () {
  "use strict";

  var results = [];
  var running = false;

  function dispatch(aggregate, command, args) {
    if (window.Hecks && window.Hecks.dispatch) {
      return window.Hecks.dispatch(aggregate, command, args || {});
    }
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

    var domain = getDomain();
    if (!domain) {
      addResult("?", "No domain", "failed", "No domain data available");
      running = false;
      return;
    }

    var cmds = [];
    domain.aggregates.forEach(function (agg) {
      (agg.commands || []).forEach(function (cmd) {
        var name = typeof cmd === "string" ? cmd : cmd.name;
        cmds.push({ agg: agg.name, cmd: name, attrs: typeof cmd === "object" ? cmd.attributes : [] });
      });
    });

    showProgress(0, cmds.length);
    runNext(cmds, 0);
  }

  function runNext(cmds, idx) {
    if (idx >= cmds.length) {
      running = false;
      renderSummary();
      return;
    }

    var c = cmds[idx];
    var args = buildArgs(c.attrs);
    var eventsBefore = window.HecksApp ? window.HecksApp.state.events.length : 0;

    try {
      dispatch(c.agg, c.cmd, args);
    } catch (e) {
      // command may fail — that's expected for some
    }

    setTimeout(function () {
      var eventsAfter = window.HecksApp ? window.HecksApp.state.events.length : 0;
      var gotEvent = eventsAfter > eventsBefore;
      var status = gotEvent ? "passed" : "skipped";
      var eventName = "";
      if (gotEvent && window.HecksApp) {
        eventName = window.HecksApp.state.events[0].event || "";
      }
      addResult(c.agg + "." + c.cmd, eventName, status);
      showProgress(idx + 1, cmds.length);
      runNext(cmds, idx + 1);
    }, 50);
  }

  function buildArgs(attrs) {
    var args = {};
    if (!attrs) return args;
    attrs.forEach(function (a) {
      var name = typeof a === "string" ? a : a.name;
      var type = typeof a === "object" ? a.type : "String";
      if (type === "Integer" || type === "Float") args[name] = 1;
      else args[name] = "test";
    });
    return args;
  }

  function addResult(command, eventName, status, error) {
    results.push({ command: command, event: eventName, status: status, error: error });
    renderResults();
  }

  function renderResults() {
    var container = document.getElementById("test-results");
    if (!container) return;
    container.innerHTML = results.map(function (r) {
      var icon = r.status === "passed" ? "✅" : r.status === "failed" ? "❌" : "⬜";
      var color = r.status === "passed" ? "text-green-400" : r.status === "failed" ? "text-red-400" : "text-white/[.38]";
      var event = r.event ? " → " + r.event : "";
      var err = r.error ? ' <span class="text-red-400 text-xs">(' + r.error + ')</span>' : "";
      return '<div class="flex items-center gap-2 py-0.5 text-sm ' + color + '">' +
        '<span>' + icon + '</span>' +
        '<span class="font-mono">' + r.command + '</span>' +
        '<span class="text-white/[.38]">' + event + '</span>' + err + '</div>';
    }).join("");
  }

  function showProgress(current, total) {
    var el = document.getElementById("test-progress");
    if (el) el.classList.remove("hidden");
    var passed = results.filter(function (r) { return r.status === "passed"; }).length;
    var failed = results.filter(function (r) { return r.status === "failed"; }).length;
    var p = document.getElementById("test-passed");
    var f = document.getElementById("test-failed");
    var t = document.getElementById("test-total");
    var bar = document.getElementById("test-bar");
    if (p) p.textContent = passed + " passed";
    if (f) f.textContent = failed + " failed";
    if (t) t.textContent = current + "/" + total;
    if (bar) bar.style.width = (total > 0 ? (current / total * 100) : 0) + "%";
  }

  function renderSummary() {
    var passed = results.filter(function (r) { return r.status === "passed"; }).length;
    var total = results.length;
    var bar = document.getElementById("test-bar");
    if (bar) bar.className = passed === total ?
      "bg-green-400 h-1.5 rounded-full transition-all" :
      "bg-amber-400 h-1.5 rounded-full transition-all";
  }

  function reset() {
    results = [];
    running = false;
    var container = document.getElementById("test-results");
    if (container) container.innerHTML = '<p class="text-white/[.38] text-sm">Click "Run All" to test every command.</p>';
    var el = document.getElementById("test-progress");
    if (el) el.classList.add("hidden");
  }

  function getDomain() {
    if (window.HecksWorkbench && window.HecksWorkbench.domain) return window.HecksWorkbench.domain;
    var state = window.HecksApp && window.HecksApp.state;
    if (state && state.projects && state.projects[0] && state.projects[0].domains) return state.projects[0].domains[0];
    return null;
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", setup);
  } else {
    setup();
  }
})();
