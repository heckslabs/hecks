// HecksAppeal IDE — Action Delegation + Sidebar Tree
//
// All UI actions dispatch through HecksClientState.dispatch() for
// optimistic local + server persistence. Falls back to Hecks.dispatch.
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
          if (window.HecksApp) {
            var s = window.HecksApp.getState();
            window.HecksApp.handleEvent({ event: "SidebarToggled", data: { sidebar_collapsed: !s.layout.sidebarCollapsed } });
          }
          dispatch("Layout", "ToggleSidebar");
          break;
        case "toggle-events":
          if (window.HecksApp) {
            var st = window.HecksApp.getState();
            window.HecksApp.handleEvent({ event: "EventsPanelToggled", data: { events_collapsed: !st.layout.eventsCollapsed } });
          }
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
      var tabName = tab.dataset.tab;
      // Local first for instant UI, then persist to server
      if (window.HecksApp) window.HecksApp.handleEvent({ event: "TabSelected", data: { tab_name: tabName } });
      dispatch("Layout", "SelectTab", { tab_name: tabName });
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
      var isHidden = detail.classList.contains("hidden");
      detail.classList.toggle("hidden");
      if (arrow) arrow.textContent = isHidden ? "\u25BE" : "\u25B8";
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

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
