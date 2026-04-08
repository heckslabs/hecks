// HecksAppeal IDE — WebSocket Command/Event Protocol
//
// Connects to the IDE server via WebSocket. Sends domain commands
// and routes incoming events to the application state manager.
//
//   Protocol (client -> server):
//     { type: "command", aggregate: "Layout", command: "ToggleSidebar", args: {} }
//
//   Protocol (server -> client):
//     { type: "state", data: { projects: [...] } }
//     { type: "event", event: "SidebarToggled", aggregate: "Layout", data: { collapsed: true } }
//
//   Usage:
//     HecksIDE.command("Layout", "ToggleSidebar", {});
//

(function () {
  "use strict";

  var ws = null;
  var reconnectDelay = 1000;
  var maxReconnectDelay = 10000;

  function connect() {
    var protocol = location.protocol === "https:" ? "wss:" : "ws:";
    var port = parseInt(location.port || "80", 10) + 1;
    var url = protocol + "//" + location.hostname + ":" + port + "/ws";

    setConnectionStatus("connecting");
    ws = new WebSocket(url);

    ws.onopen = function () {
      reconnectDelay = 1000;
      setConnectionStatus("connected");
      if (window.HecksApp) {
        window.HecksApp.state.status.connected = true;
      }
      // runAutoCommand();
    };

    ws.onmessage = function (event) {
      var msg;
      try { msg = JSON.parse(event.data); } catch (e) { return; }
      routeMessage(msg);
    };

    ws.onclose = function () {
      setConnectionStatus("disconnected");
      if (window.HecksApp) {
        window.HecksApp.state.status.connected = false;
      }
      setTimeout(function () {
        reconnectDelay = Math.min(reconnectDelay * 1.5, maxReconnectDelay);
        connect();
      }, reconnectDelay);
    };

    ws.onerror = function () {
      ws.close();
    };
  }

  function command(aggregate, commandName, args) {
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({
        type: "command",
        aggregate: aggregate,
        command: commandName,
        args: args || {}
      }));
    }
  }

  function routeMessage(msg) {
    if (!window.HecksApp) return;

    switch (msg.type) {
      case "state":
        window.HecksApp.handleEvent({ event: "StateLoaded", data: msg.data });
        break;
      case "event":
        window.HecksApp.handleEvent(msg);
        break;
    }
  }

  function setConnectionStatus(connectionState) {
    var el = document.getElementById("connection-status");
    if (!el) return;

    var dot = el.querySelector("span");
    if (dot) {
      dot.className = "w-2 h-2 rounded-full " + statusColor(connectionState);
    }

    var labels = { connected: "Connected", disconnected: "Disconnected", connecting: "Connecting..." };
    var text = labels[connectionState] || connectionState;
    var last = el.lastChild;
    if (last && last.nodeType === 3) {
      last.textContent = " " + text;
    }
  }

  function statusColor(connectionState) {
    switch (connectionState) {
      case "connected": return "bg-green-500";
      case "connecting": return "bg-yellow-500";
      default: return "bg-red-500";
    }
  }

  function streamConsoleErrors() {
    var origError = console.error;
    console.error = function () {
      origError.apply(console, arguments);
      var msg = Array.prototype.slice.call(arguments).join(" ");
      command("Debug", "ConsoleError", { message: msg });
    };
    window.onerror = function (msg, source, line) {
      command("Debug", "ConsoleError", { message: msg + " at " + source + ":" + line });
    };
  }

  function runAutoCommand() {
    var params = new URLSearchParams(location.search);
    var autoOpen = params.get("open");
    if (autoOpen) {
      setTimeout(function () { command("Explorer", "OpenFile", { path: autoOpen }); }, 500);
    }
  }

  function init() {
    connect();
    streamConsoleErrors();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }

  function raw(data) {
    if (ws && ws.readyState === 1) ws.send(data);
  }

  window.HecksIDE = { command: command, raw: raw };
})();
