// HecksAppeal IDE — Command Tester Panel
//
// Lists all IDE command bus commands in the right panel.
// Clicking a command dispatches it live via HecksIDE.command(),
// causing the browser to execute the action visually.
//
//   Requires window.Hecks ? window.Hecks.dispatch : window.HecksIDE.command() from socket.js
//

(function () {
  "use strict";

  var IDE_COMMANDS = [
    { aggregate: "Layout", commands: [
      { name: "ToggleSidebar", args: {} },
      { name: "ToggleEventsPanel", args: {} },
      { name: "HideProjects", args: {} },
      { name: "ShowProjects", args: {} },
      { name: "SelectTab", args: { tab: "editor" } },
      { name: "SelectTab", args: { tab: "diagrams" }, label: "SelectTab (diagrams)" },
      { name: "SelectTab", args: { tab: "console" }, label: "SelectTab (console)" }
    ]},
    { aggregate: "Project", commands: [
      { name: "DiscoverProjects", args: { path: "." } },
      { name: "CloseProject", args: {} }
    ]},
    { aggregate: "Menu", commands: [
      { name: "OpenMenu", args: { menu: "file" } },
      { name: "OpenMenu", args: { menu: "view" }, label: "OpenMenu (view)" },
      { name: "OpenMenu", args: { menu: "domain" }, label: "OpenMenu (domain)" },
      { name: "CloseMenu", args: {} }
    ]},
    { aggregate: "EventStream", commands: [
      { name: "PauseStream", args: {} },
      { name: "ResumeStream", args: {} },
      { name: "ClearEvents", args: {} }
    ]},
    { aggregate: "Screenshot", commands: [
      { name: "PauseCapture", args: {} },
      { name: "ResumeCapture", args: {} }
    ]},
    { aggregate: "Explorer", commands: [], dynamic: true },
    { aggregate: "Agent", commands: [
      { name: "SendMessage", args: { content: "Hello from command tester" } },
      { name: "ClearConversation", args: {} }
    ]}
  ];

  var runState = { running: false };

  function render() {
    var container = document.getElementById("command-tester");
    if (!container) return;

    var commands = IDE_COMMANDS.map(function (group) {
      if (group.dynamic && group.aggregate === "Explorer") {
        return { aggregate: "Explorer", commands: buildExplorerCommands() };
      }
      return group;
    });

    var html = renderPlayBar();
    commands.forEach(function (group) {
      html += renderGroup(group);
    });
    container.innerHTML = html;
  }

  function renderPlayBar() {
    var html = '<div class="flex items-center gap-2 mb-2 pb-2 border-b border-white/[.08]">';
    html += '<button id="run-all-tests" class="flex items-center gap-1.5 px-3 py-1.5 text-xs font-medium rounded ';
    html += 'bg-accent hover:bg-accent-hover text-white transition-colors">';
    html += '<span class="text-sm">&#9654;</span> Run All Tests</button>';
    html += '<span id="test-progress" class="text-xs text-white/[.38]"></span>';
    html += '</div>';
    return html;
  }

  function buildExplorerCommands() {
    var state = window.HecksApp && window.HecksApp.state;
    if (!state || !state.projects) return [];
    var cmds = [];
    state.projects.forEach(function (project) {
      if (project.files) {
        project.files.forEach(function (file) {
          cmds.push({ name: "OpenFile", args: { path: file.path }, label: "Open " + file.name });
        });
      }
    });
    return cmds;
  }

  function renderGroup(group) {
    var html = '<details class="border border-white/[.08] rounded mb-1" open>';
    html += '<summary class="px-2 py-1 text-sm text-white/[.87] cursor-pointer hover:bg-white/[.04]">';
    html += '<span class="text-accent text-xs mr-1">&#9670;</span>';
    html += escapeHtml(group.aggregate);
    html += '</summary>';
    html += '<div class="px-2 pb-2 space-y-1">';
    group.commands.forEach(function (cmd) {
      html += renderButton(group.aggregate, cmd);
    });
    html += '</div></details>';
    return html;
  }

  function renderButton(aggregate, cmd) {
    var label = cmd.label || cmd.name;
    var html = '<button class="w-full text-left px-2 py-1 text-xs rounded ';
    html += 'text-white/[.70] hover:bg-accent/20 hover:text-white/[.87] ';
    html += 'transition-colors" ';
    html += "data-ide-agg=\"" + escapeHtml(aggregate) + "\" ";
    html += "data-ide-cmd=\"" + escapeHtml(cmd.name) + "\" ";
    html += "data-ide-args='" + JSON.stringify(cmd.args) + "'>";
    html += escapeHtml(label);
    html += '</button>';
    return html;
  }

  function escapeHtml(str) {
    if (!str) return "";
    var div = document.createElement("div");
    div.textContent = str;
    return div.innerHTML;
  }

  function setupClicks() {
    document.addEventListener("click", function (e) {
      var playBtn = e.target.closest("#run-all-tests");
      if (playBtn) { runAllTests(); return; }

      var btn = e.target.closest("[data-ide-cmd]");
      if (!btn) return;

      var agg = btn.dataset.ideAgg;
      var cmd = btn.dataset.ideCmd;
      var args = JSON.parse(btn.dataset.ideArgs || "{}");

            (window.Hecks ? window.Hecks.dispatch : window.HecksIDE.command)(agg, cmd, args);
      flash(btn);
    });
  }

  function flash(el) {
    el.style.backgroundColor = "rgba(67, 97, 238, 0.3)";
    setTimeout(function () {
      el.style.backgroundColor = "";
    }, 300);
  }

  function runAllTests() {
    if (runState.running) return;
    runState.running = true;

    var buttons = document.querySelectorAll("[data-ide-cmd]");
    var total = buttons.length;
    var passed = 0;
    var failed = 0;
    var index = 0;

    var playBtn = document.getElementById("run-all-tests");
    if (playBtn) {
      playBtn.innerHTML = '<span class="text-sm animate-spin inline-block">&#8635;</span> Running...';
      playBtn.classList.add("opacity-60", "pointer-events-none");
    }

    // Reset all badges
    buttons.forEach(function (btn) {
      var badge = btn.querySelector(".test-badge");
      if (badge) badge.remove();
    });

    function runNext() {
      if (index >= total) {
        finish();
        return;
      }

      var btn = buttons[index];
      var agg = btn.dataset.ideAgg;
      var cmd = btn.dataset.ideCmd;
      var args = JSON.parse(btn.dataset.ideArgs || "{}");

      // Scroll button into view
      btn.scrollIntoView({ block: "nearest", behavior: "smooth" });

      // Snapshot DOM before firing (exclude right panel where test buttons live)
      var domBefore = snapshotDOM();

      // Fire the command
            (window.Hecks ? window.Hecks.dispatch : window.HecksIDE.command)(agg, cmd, args);
      flash(btn);

      updateProgress(index + 1, total, passed, failed);

      // Wait for server response, then check DOM changed
      setTimeout(function () {
        var domAfter = snapshotDOM();
        var ok = domAfter !== domBefore;

        if (ok) {
          passed++;
          markResult(btn, true);
        } else {
          failed++;
          markResult(btn, false);
        }

        updateProgress(index + 1, total, passed, failed);
        index++;
        runNext();
      }, 400);
    }

    function finish() {
      runState.running = false;
      if (playBtn) {
        playBtn.innerHTML = '<span class="text-sm">&#9654;</span> Run All Tests';
        playBtn.classList.remove("opacity-60", "pointer-events-none");
      }
      var progressEl = document.getElementById("test-progress");
      if (progressEl) {
        var color = failed === 0 ? "text-green-400" : "text-red-400";
        progressEl.className = "text-xs font-medium " + color;
        progressEl.textContent = passed + "/" + total + " passed";
      }
    }

    runNext();
  }

  function markResult(btn, ok) {
    var existing = btn.querySelector(".test-badge");
    if (existing) existing.remove();
    var badge = document.createElement("span");
    badge.className = "test-badge ml-auto text-xs font-bold " + (ok ? "text-green-400" : "text-red-400");
    badge.textContent = ok ? "\u2713" : "\u2717";
    btn.style.display = "flex";
    btn.style.alignItems = "center";
    btn.appendChild(badge);
  }

  function snapshotDOM() {
    var ide = document.getElementById("ide");
    if (!ide) return "";
    var clone = ide.cloneNode(true);
    var rightPanel = clone.querySelector("#right-panel");
    if (rightPanel) rightPanel.remove();
    return clone.innerHTML;
  }

  function updateProgress(current, total, passed, failed) {
    var el = document.getElementById("test-progress");
    if (!el) return;
    el.className = "text-xs text-white/[.54]";
    el.textContent = current + "/" + total + (failed > 0 ? " (" + failed + " failed)" : "");
  }

  function setupRightTabs() {
    document.addEventListener("click", function (e) {
      var tab = e.target.closest("[data-right-tab]");
      if (!tab) return;

      var name = tab.dataset.rightTab;
      var tabs = document.querySelectorAll("[data-right-tab]");
      tabs.forEach(function (t) {
        var active = t.dataset.rightTab === name;
        t.setAttribute("aria-selected", active ? "true" : "false");
        if (active) {
          t.className = "px-4 h-9 text-sm text-white/[.87] border-b-2 border-accent bg-white/[.04]";
        } else {
          t.className = "px-4 h-9 text-sm text-white/[.54] hover:text-white/[.87] border-b-2 border-transparent hover:bg-white/[.04] transition-colors";
        }
      });

      var panels = { agent: "panel-agent", commands: "panel-commands" };
      Object.keys(panels).forEach(function (key) {
        var panel = document.getElementById(panels[key]);
        if (panel) panel.style.display = key === name ? "" : "none";
      });
    });
  }

  function init() {
    setupClicks();
    setupRightTabs();
    render();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }

  window.HecksCommandTester = { render: render };
})();
