// HecksAppeal IDE — Action Delegation + Sidebar Tree
//
// Handles toolbar button clicks (toggle sidebar, toggle events,
// pause/resume stream, clear events) and sidebar tree navigation
// (expand/collapse groups, select items). All actions dispatch
// domain commands via HecksIDE.command().
//
//   Requires window.HecksIDE.command() from socket.js
//

(function () {
  "use strict";

  function setupActions() {
    document.addEventListener("click", function (e) {
      var actionEl = e.target.closest("[data-action]");
      if (!actionEl) return;
      if (actionEl.dataset.action === "menu-action") return;
      if (actionEl.dataset.action === "send-message") return;

      var action = actionEl.dataset.action;
      var cmd = window.HecksIDE.command;

      var dispatch = window.Hecks ? window.Hecks.dispatch : cmd;

      switch (action) {
        case "toggle-sidebar":
        case "toggle-projects":
        case "expand-sidebar":
          dispatch("Layout", "ToggleSidebar", {});
          break;
        case "toggle-events":
          dispatch("Layout", "ToggleEventsPanel", {});
          break;
        case "pause-stream":
          dispatch("EventStream", "PauseStream", {});
          break;
        case "clear-events":
          dispatch("EventStream", "ClearEvents", {});
          break;
      }
    });
  }

  function setupSidebarTree() {
    document.addEventListener("click", function (e) {
      var item = e.target.closest(".tree-item");
      if (!item) return;

      if (item.dataset.expandable === "true") {
        if (item.dataset.kind === "project") {
          window.HecksIDE.command("Diagram", "GenerateOverview", {});
        }
        var group = item.nextElementSibling;
        if (group && group.classList.contains("tree-group")) {
          var hidden = group.hidden;
          group.hidden = !hidden;
          item.setAttribute("aria-expanded", String(hidden));
          var icon = item.querySelector(".icon");
          if (icon) icon.textContent = hidden ? "\u25BE" : "\u25B8";
        }
        return;
      }

      document.querySelectorAll(".tree-item.active").forEach(function (el) {
        el.classList.remove("active");
      });
      item.classList.add("active");

      var cmd = window.HecksIDE.command;
      var kind = item.dataset.kind;

      if (kind === "aggregate") {
        cmd("Explorer", "InspectAggregate", { aggregate_name: item.dataset.aggregate });
      } else if (kind === "file") {
        cmd("Explorer", "OpenFile", { path: item.dataset.path });
      }
    });
  }

  function setupTabs() {
    document.addEventListener("click", function (e) {
      var tab = e.target.closest("[data-tab]");
      if (!tab) return;
      var tabName = tab.dataset.tab;
      // Dispatch locally — tab switching is a UI concern
      if (window.HecksApp) {
        window.HecksApp.handleEvent({ event: "TabSelected", data: { tab: tabName } });
      }
    });
  }

  function setupEventExpand() {
    document.addEventListener("click", function (e) {
      var trigger = e.target.closest("[data-action='toggle-event-detail']");
      if (!trigger) return;
      var row = trigger.closest(".event-row");
      if (!row) return;
      var detail = row.querySelector(".event-detail");
      var arrow = row.querySelector(".event-arrow");
      if (!detail) return;
      var isHidden = detail.classList.contains("hidden");
      detail.classList.toggle("hidden");
      if (arrow) arrow.textContent = isHidden ? "\u25BE" : "\u25B8";
    });
  }

  function init() {
    setupActions();
    setupSidebarTree();
    setupTabs();
    setupEventExpand();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
