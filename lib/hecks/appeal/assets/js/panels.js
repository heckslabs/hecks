// HecksAppeal IDE — Panel Interactions
//
// Agent chat, console forms, adapter toggle. All dispatch through
// Hecks.dispatch() — domain commands, not infrastructure.
//

(function () {
  "use strict";

  function dispatch(aggregate, command, args) {
    if (window.Hecks && window.Hecks.dispatch) {
      return window.Hecks.dispatch(aggregate, command, args || {});
    } else if (window.HecksIDE && window.HecksIDE.command) {
      window.HecksIDE.command(aggregate, command, args || {});
    }
  }

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
    dispatch("Agent", "SendMessage", { content: content });
  }

  function setupConsoleForm() {
    document.addEventListener("submit", function (e) {
      var form = e.target.closest("[data-console-form]");
      if (!form) return;
      e.preventDefault();
      var data = {};
      new FormData(form).forEach(function (value, key) { data[key] = value; });
      dispatch("Console", "SubmitForm", { values: JSON.stringify(data) });
    });

    document.addEventListener("change", function (e) {
      if (e.target.name === "aggregate" || e.target.name === "command") {
        var aggEl = document.querySelector("[name='aggregate']");
        var cmdEl = document.querySelector("[name='command']");
        dispatch("Console", "SelectCommand", {
          aggregate_name: aggEl ? aggEl.value : "",
          command_name: cmdEl ? cmdEl.value : ""
        });
      }
    });
  }

  function setupSendButton() {
    document.addEventListener("click", function (e) {
      if (e.target.closest("[data-action='send-message']")) sendAgentMessage();
    });
  }

  function init() {
    setupAgentInput();
    setupConsoleForm();
    setupSendButton();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
