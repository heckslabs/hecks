// HecksAppeal IDE — Panel Interactions
//
// Handles agent chat input, console form submission,
// and aggregate/command selection changes. All interactions
// dispatch domain commands via HecksIDE.command().
//
//   Requires window.HecksIDE.command() from socket.js
//

(function () {
  "use strict";

  function setupAgentInput() {
    document.addEventListener("keydown", function (e) {
      if (e.target.id !== "agent-input-field") return;
      if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault();
        sendAgentMessage();
      }
    });
  }

  function sendAgentMessage() {
    var input = document.getElementById("agent-input-field");
    if (!input || !input.value.trim()) return;

    var content = input.value.trim();
    input.value = "";

    window.HecksIDE.command("Agent", "SendMessage", { content: content });
  }

  function setupConsoleForm() {
    document.addEventListener("submit", function (e) {
      var form = e.target.closest("[data-console-form]");
      if (!form) return;

      e.preventDefault();
      var data = {};
      new FormData(form).forEach(function (value, key) {
        data[key] = value;
      });

      window.HecksIDE.command("Console", "SubmitForm", { values: JSON.stringify(data) });
    });

    document.addEventListener("change", function (e) {
      if (e.target.name === "aggregate" || e.target.name === "command") {
        var aggEl = document.querySelector("[name='aggregate']");
        var cmdEl = document.querySelector("[name='command']");
        window.HecksIDE.command("Console", "SelectCommand", {
          aggregate_name: aggEl ? aggEl.value : "",
          command_name: cmdEl ? cmdEl.value : ""
        });
      }
    });
  }

  function setupSendButton() {
    document.addEventListener("click", function (e) {
      var btn = e.target.closest("[data-action='send-message']");
      if (btn) sendAgentMessage();
    });
  }

  function setupAdapterToggle() {
    document.addEventListener("click", function (e) {
      var btn = e.target.closest("[data-action='toggle-adapter']");
      if (!btn) return;
      var label = document.getElementById("agent-mode-label");
      var current = label ? label.textContent.trim() : "memory";
      var next = current === "memory" ? "live" : "memory";
      window.HecksIDE.command("Agent", "ToggleAdapter", { mode: next });
    });
  }

  function init() {
    setupAgentInput();
    setupConsoleForm();
    setupSendButton();
    setupAdapterToggle();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
