// HecksAppeal IDE — Action Delegation + Sidebar Tree
//
// All UI actions dispatch through HecksClientState.dispatch() which
// handles optimistic local events + server persistence automatically.
//

(function () {
  "use strict";

  function dispatch(aggregate, command, args) {
    if (window.HecksClientState && window.HecksClientState.dispatch) {
      return window.HecksClientState.dispatch(aggregate, command, args || {});
    } else if (window.Hecks && window.Hecks.dispatch) {
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
          } else {
            dispatch("EventStream", "PauseStream");
            actionEl.textContent = "Paused";
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
        if (item.dataset.kind === "project") dispatch("Diagram", "GenerateOverview");
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

      document.querySelectorAll(".tree-item.active").forEach(function (el) { el.classList.remove("active"); });
      item.classList.add("active");

      if (item.dataset.kind === "aggregate") dispatch("Explorer", "InspectAggregate", { aggregate_name: item.dataset.aggregate });
      else if (item.dataset.kind === "file") dispatch("Explorer", "OpenFile", { path: item.dataset.path });
    });
  }

  function setupTabs() {
    document.addEventListener("click", function (e) {
      var tab = e.target.closest("[data-tab]");
      if (!tab) return;
      dispatch("Layout", "SelectTab", { tab_name: tab.dataset.tab });
    });
  }

  function setupSearch() {
    document.addEventListener("keyup", function (e) {
      if (e.target.id !== "search-input") return;
      var q = e.target.value.trim();
      if (q) dispatch("Search", "SearchDomain", { query: q });
      else dispatch("Search", "ClearSearch");
    });
  }

  function setupEventFilter() {
    document.addEventListener("keyup", function (e) {
      if (e.target.id !== "event-filter-input") return;
      var q = e.target.value.trim().toLowerCase();
      document.querySelectorAll(".event-row").forEach(function (row) {
        row.style.display = (!q || row.textContent.toLowerCase().indexOf(q) >= 0) ? "" : "none";
      });
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
      detail.classList.toggle("hidden");
      if (arrow) arrow.textContent = detail.classList.contains("hidden") ? "\u25B8" : "\u25BE";
    });
  }

  function init() {
    setupActions();
    setupSidebarTree();
    setupTabs();
    setupSearch();
    setupEventFilter();
    setupEventExpand();
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();
})();
