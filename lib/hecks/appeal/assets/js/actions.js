// HecksAppeal IDE — Action Delegation + Sidebar Tree
//
// All UI actions dispatch through Hecks.dispatch() which routes
// to client-side or server based on the domain IR.
//
//   Requires window.Hecks.dispatch() from /hecks/client.js
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

  function setupActions() {
    document.addEventListener("click", function (e) {
      var actionEl = e.target.closest("[data-action]");
      if (!actionEl) return;
      if (actionEl.dataset.action === "menu-action") return;
      if (actionEl.dataset.action === "send-message") return;

      switch (actionEl.dataset.action) {
        case "toggle-sidebar":
        case "toggle-projects":
        case "expand-sidebar":
          dispatch("Layout", "ToggleSidebar");
          break;
        case "toggle-events":
          dispatch("Layout", "ToggleEventsPanel");
          break;
        case "pause-stream":
          var isPaused = actionEl.textContent.trim() === "Paused";
          if (isPaused) {
            dispatch("EventStream", "ResumeStream");
            actionEl.textContent = "Pause";
            actionEl.setAttribute("aria-label", "Pause Event Stream");
          } else {
            dispatch("EventStream", "PauseStream");
            actionEl.textContent = "Paused";
            actionEl.setAttribute("aria-label", "Resume Event Stream");
          }
          break;
        case "clear-events":
          dispatch("EventStream", "ClearEvents");
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
          dispatch("Diagram", "GenerateOverview");
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

      var kind = item.dataset.kind;
      if (kind === "aggregate") {
        dispatch("Explorer", "InspectAggregate", { aggregate_name: item.dataset.aggregate });
      } else if (kind === "file") {
        dispatch("Explorer", "OpenFile", { path: item.dataset.path });
      }
    });
  }

  function setupTabs() {
    document.addEventListener("click", function (e) {
      var tab = e.target.closest("[data-tab]");
      if (!tab) return;
      dispatch("Layout", "SelectTab", { tab_name: tab.dataset.tab });
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

  function setupSearch() {
    var input = document.getElementById("search-input");
    if (!input) return;
    input.addEventListener("keyup", function () {
      var query = input.value.trim();
      if (query.length > 0) {
        dispatch("Search", "SearchDomain", { query: query });
      } else {
        dispatch("Search", "ClearSearch");
      }
    });
  }

  function setupEventFilter() {
    var input = document.getElementById("event-filter-input");
    if (!input) return;
    input.addEventListener("keyup", function () {
      var filter = input.value.trim().toLowerCase();
      var rows = document.querySelectorAll("#events-content .event-row");
      rows.forEach(function (row) {
        var text = row.textContent.toLowerCase();
        row.style.display = text.indexOf(filter) !== -1 ? "" : "none";
      });
    });
  }

  function init() {
    setupActions();
    setupSidebarTree();
    setupTabs();
    setupEventExpand();
    setupSearch();
    setupEventFilter();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
