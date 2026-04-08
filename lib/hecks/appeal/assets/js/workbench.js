// HecksAppeal IDE — Workbench Panel
//
// Hecks console with sketch/play modes. All commands pass through
// the domain command bus via HecksIDE.command(). The workbench
// listens for response events and displays them in the REPL.
//
//   sketch> — inspect and author domain structure
//   play>   — execute commands and watch events fire
//
//   Every input dispatches through HecksIDE.command() to the server.
//

(function () {
  "use strict";

  var mode = "sketch";
  var history = [];
  var historyIndex = -1;

  // -- Mode Toggle --

  function setupModeToggle() {
    document.addEventListener("click", function (e) {
      var btn = e.target.closest("[data-sketchmode]");
      if (!btn) return;
      setMode(btn.dataset.sketchmode);
    });
  }

  function setMode(newMode) {
    mode = newMode;
    var buttons = document.querySelectorAll(".workbench-mode");
    buttons.forEach(function (b) {
      var active = b.dataset.sketchmode === mode;
      b.className = "workbench-mode px-3 py-1 text-xs font-medium " +
        (active ? "text-white/[.87] bg-accent" : "text-white/[.54] hover:text-white/[.87]");
    });

    var prompt = document.getElementById("workbench-prompt");
    if (prompt) prompt.textContent = mode === "sketch" ? "sketch>" : "play>";

    var input = document.getElementById("workbench-input");
    if (input) {
      input.placeholder = mode === "sketch"
        ? "Session.EnterSketch or: aggregate Layout"
        : "Layout.ToggleSidebar or: SelectTab tab:editor";
    }

    // Fire the mode switch through the domain
    var cmd = mode === "sketch" ? "EnterSketch" : "EnterPlay";
    fireAndLog("Session", cmd, {});
  }

  // -- REPL --

  function setupInput() {
    var input = document.getElementById("workbench-input");
    if (!input) return;

    input.addEventListener("keydown", function (e) {
      if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault();
        var line = input.value.trim();
        if (!line) return;
        history.unshift(line);
        historyIndex = -1;
        input.value = "";
        execute(line);
      } else if (e.key === "ArrowUp") {
        e.preventDefault();
        if (historyIndex < history.length - 1) {
          historyIndex++;
          input.value = history[historyIndex];
        }
      } else if (e.key === "ArrowDown") {
        e.preventDefault();
        if (historyIndex > 0) {
          historyIndex--;
          input.value = history[historyIndex];
        } else {
          historyIndex = -1;
          input.value = "";
        }
      }
    });
  }

  function execute(line) {
    var promptStr = mode === "sketch" ? "sketch> " : "play> ";
    appendOutput("input", promptStr + line);

    // Local-only commands
    if (line === "help") { showHelp(); return; }
    if (line === "clear") { clearOutput(); return; }
    if (line === "list") { showCommands(); return; }

    // "Aggregate.Command key:val" — explicit dispatch
    var dotMatch = line.match(/^(\w+)\.(\w+)\s*(.*)$/);
    if (dotMatch) {
      fireAndLog(dotMatch[1], dotMatch[2], parseArgs(dotMatch[3] || ""));
      return;
    }

    // "CommandName key:val" — auto-find aggregate
    var cmdMatch = line.match(/^(\w+)\s*(.*)$/);
    if (cmdMatch) {
      var cmdName = cmdMatch[1];
      var args = parseArgs(cmdMatch[2] || "");
      var agg = findAggregateForCommand(cmdName);
      if (agg) {
        fireAndLog(agg.name, cmdName, args);
      } else {
        appendOutput("warn", "'" + cmdName + "' not found in any aggregate");
        appendOutput("hint", "Available: " + allCommandNames().join(", "));
      }
      return;
    }

    appendOutput("warn", "Could not parse. Use Aggregate.Command or CommandName.");
  }

  // -- Fire command through domain bus and log the response --

  function fireAndLog(aggregate, command, args) {
    appendOutput("exec", ">>> " + aggregate + "." + command + "(" + JSON.stringify(args) + ")");

    var dispatch = window.Hecks ? window.Hecks.dispatch : window.HecksIDE.command;
    var isClient = window.Hecks && window.Hecks.state && window.Hecks.state[aggregate];

    if (isClient) {
      // Client-side: execute immediately, show result
      var result = dispatch(aggregate, command, args);
      if (result && result.event) {
        appendOutput("event", "<<< " + result.event + " " + JSON.stringify(result.data || {}));
      } else {
        appendOutput("warn", "<<< no event returned");
      }
    } else {
      // Server-side: dispatch over WebSocket, wait for response
      var countBefore = window.HecksApp.state.events.length;
      dispatch(aggregate, command, args);

      setTimeout(function () {
        var newEvents = window.HecksApp.state.events.length - countBefore;
        if (newEvents > 0) {
          for (var i = newEvents - 1; i >= 0; i--) {
            var ev = window.HecksApp.state.events[i];
            var dataStr = ev.data ? " " + JSON.stringify(ev.data) : "";
            appendOutput("event", "<<< " + (ev.event || "?") + dataStr);
          }
        } else {
          appendOutput("warn", "<<< no event received (server may not handle this command yet)");
        }
      }, 500);
    }
  }

  function parseArgs(str) {
    var args = {};
    if (!str) return args;
    var pairs = str.match(/(\w+):("[^"]*"|\S+)/g);
    if (pairs) {
      pairs.forEach(function (pair) {
        var kv = pair.split(":");
        var key = kv[0];
        var val = kv.slice(1).join(":").replace(/^"|"$/g, "");
        args[key] = val;
      });
    }
    return args;
  }

  // -- Domain helpers --

  function allDomains() {
    var state = window.HecksApp && window.HecksApp.state;
    if (!state || !state.projects) return [];
    var domains = [];
    state.projects.forEach(function (p) {
      if (p.domains) domains = domains.concat(p.domains);
    });
    return domains;
  }

  function findAggregateForCommand(cmdName) {
    var result = null;
    // Check project domains
    allDomains().forEach(function (d) {
      if (d.aggregates) d.aggregates.forEach(function (a) {
        if (a.commands && a.commands.indexOf(cmdName) !== -1) result = a;
      });
    });
    if (result) return result;
    // Check client-side handlers
    if (window.Hecks && window.Hecks.handlers) {
      var keys = Object.keys(window.Hecks.handlers);
      for (var i = 0; i < keys.length; i++) {
        var parts = keys[i].split(".");
        if (parts[1] === cmdName) return { name: parts[0], commands: [cmdName] };
      }
    }
    return null;
  }

  function allCommandNames() {
    var names = [];
    allDomains().forEach(function (d) {
      if (d.aggregates) d.aggregates.forEach(function (a) {
        if (a.commands) names = names.concat(a.commands);
      });
    });
    // Add client-side commands
    if (window.Hecks && window.Hecks.handlers) {
      Object.keys(window.Hecks.handlers).forEach(function (key) {
        var cmd = key.split(".")[1];
        if (names.indexOf(cmd) === -1) names.push(cmd);
      });
    }
    return names;
  }

  // -- Output --

  var STYLES = {
    input:  "text-white/[.54]",
    info:   "text-white/[.70]",
    exec:   "text-accent",
    event:  "text-green-400",
    policy: "text-amber-400",
    warn:   "text-red-400",
    hint:   "text-white/[.38] italic",
    system: "text-white/[.32] italic"
  };

  function appendOutput(kind, text) {
    var container = document.getElementById("workbench-output");
    if (!container) return;
    var cls = STYLES[kind] || "text-white/[.70]";
    var line = '<div class="' + cls + ' leading-relaxed whitespace-pre-wrap">' + esc(text) + '</div>';
    container.insertAdjacentHTML("beforeend", line);
    container.scrollTop = container.scrollHeight;
  }

  function clearOutput() {
    var container = document.getElementById("workbench-output");
    if (container) container.innerHTML = "";
  }

  function showHelp() {
    appendOutput("info", "Workbench — dispatch commands through Hecks.dispatch");
    appendOutput("hint", "");
    appendOutput("hint", "  Aggregate.Command key:val  — explicit dispatch");
    appendOutput("hint", "  CommandName key:val         — auto-find aggregate");
    appendOutput("hint", "  list                       — show all commands");
    appendOutput("hint", "  clear                      — clear output");
    appendOutput("hint", "  help                       — this message");
    appendOutput("hint", "");
    appendOutput("info", "Client-side commands execute instantly.");
    appendOutput("info", "Server commands go over WebSocket.");
    appendOutput("hint", "");
    appendOutput("info", "Examples:");
    appendOutput("hint", "  Menu.OpenMenu menu_name:file");
    appendOutput("hint", "  Session.EnterPlay");
    appendOutput("hint", "  ToggleSidebar");
  }

  function showCommands() {
    // Client-side commands
    if (window.Hecks && window.Hecks.handlers) {
      appendOutput("info", "Client-side commands:");
      var seen = {};
      Object.keys(window.Hecks.handlers).forEach(function (key) {
        var parts = key.split(".");
        if (!seen[parts[0]]) { seen[parts[0]] = []; }
        seen[parts[0]].push(parts[1]);
      });
      Object.keys(seen).forEach(function (agg) {
        appendOutput("event", "  " + agg + ": " + seen[agg].join(", "));
      });
    }
    // Server-side commands from loaded projects
    var domains = allDomains();
    if (domains.length > 0) {
      appendOutput("info", "Server commands (from projects):");
      domains.forEach(function (d) {
        if (d.aggregates) d.aggregates.forEach(function (a) {
          if (a.commands && a.commands.length > 0) {
            appendOutput("hint", "  " + a.name + ": " + a.commands.join(", "));
          }
        });
      });
    }
  }

  function esc(str) {
    return window.HecksRenderer.escapeHtml(str);
  }

  // -- Init --

  function init() {
    setupModeToggle();
    setupInput();
    appendOutput("system", "HecksAppeal Workbench — type 'help' for commands");
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
