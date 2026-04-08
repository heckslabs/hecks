// HecksAppeal IDE — Keyboard Navigation & Shortcuts
//
// All shortcuts dispatch through Hecks.dispatch() which routes
// to client-side or server based on the domain IR.
//
//   Ctrl+B         — toggle sidebar
//   Ctrl+`         — toggle events panel
//   Ctrl+1/2/3/4   — switch tabs (editor/diagrams/console/workbench)
//   Ctrl+Z         — undo
//   Ctrl+Shift+Z   — redo
//   Ctrl+F         — search domain
//   Ctrl+E         — export bluebook
//   Ctrl+G         — show glossary
//   Ctrl+D         — generate overview diagram
//   Escape         — close menu
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

  var TAB_NAMES = ["editor", "diagrams", "console", "workbench"];

  // ── Tab Navigation with Arrow Keys ──────────────────────────

  document.addEventListener("keydown", function (e) {
    var tab = e.target.closest("[role='tab']");
    if (!tab) return;

    var tablist = tab.closest("[role='tablist']");
    if (!tablist) return;

    var tabs = Array.from(tablist.querySelectorAll("[role='tab']"));
    var index = tabs.indexOf(tab);

    if (e.key === "ArrowRight" || e.key === "ArrowDown") {
      e.preventDefault();
      var next = tabs[(index + 1) % tabs.length];
      next.focus();
      next.click();
    } else if (e.key === "ArrowLeft" || e.key === "ArrowUp") {
      e.preventDefault();
      var prev = tabs[(index - 1 + tabs.length) % tabs.length];
      prev.focus();
      prev.click();
    } else if (e.key === "Home") {
      e.preventDefault();
      tabs[0].focus();
      tabs[0].click();
    } else if (e.key === "End") {
      e.preventDefault();
      tabs[tabs.length - 1].focus();
      tabs[tabs.length - 1].click();
    }
  });

  // ── Tree Navigation with Arrow Keys ─────────────────────────

  document.addEventListener("keydown", function (e) {
    var item = e.target.closest(".tree-item");
    if (!item) return;

    var container = item.closest(".sidebar-content");
    if (!container) return;

    var items = Array.from(container.querySelectorAll(".tree-item:not([hidden])"));
    var index = items.indexOf(item);

    if (e.key === "ArrowDown") {
      e.preventDefault();
      if (index < items.length - 1) items[index + 1].focus();
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      if (index > 0) items[index - 1].focus();
    } else if (e.key === "Enter" || e.key === " ") {
      e.preventDefault();
      item.click();
    } else if (e.key === "ArrowRight" && item.dataset.expandable === "true") {
      e.preventDefault();
      var group = item.nextElementSibling;
      if (group && group.hidden) item.click();
    } else if (e.key === "ArrowLeft" && item.dataset.expandable === "true") {
      e.preventDefault();
      var group2 = item.nextElementSibling;
      if (group2 && !group2.hidden) item.click();
    }
  });

  // ── Global Shortcuts ────────────────────────────────────────

  document.addEventListener("keydown", function (e) {
    var mod = e.metaKey || e.ctrlKey;

    if (mod && e.key === "b") {
      e.preventDefault();
      dispatch("Layout", "ToggleSidebar");
    } else if (mod && e.key === "`") {
      e.preventDefault();
      dispatch("Layout", "ToggleEventsPanel");
    } else if (mod && e.key >= "1" && e.key <= "4") {
      e.preventDefault();
      dispatch("Layout", "SelectTab", { tab_name: TAB_NAMES[parseInt(e.key) - 1] });
    } else if (mod && e.shiftKey && e.key === "Z") {
      e.preventDefault();
      dispatch("Timeline", "Redo");
    } else if (mod && e.key === "z") {
      e.preventDefault();
      dispatch("Timeline", "Undo");
    } else if (mod && e.key === "f") {
      e.preventDefault();
      dispatch("Search", "SearchDomain");
      var input = document.querySelector("[data-search-input]");
      if (input) input.focus();
    } else if (e.key === "Escape") {
      dispatch("Menu", "CloseMenu");
    } else if (mod && e.key === "e") {
      e.preventDefault();
      dispatch("Explorer", "ExportBluebook", { format: "bluebook" });
    } else if (mod && e.key === "g") {
      e.preventDefault();
      dispatch("Glossary", "ShowGlossary");
    } else if (mod && e.key === "d") {
      e.preventDefault();
      dispatch("Diagram", "GenerateOverview");
    }
  });

  // ── Focus Management ────────────────────────────────────────

  document.addEventListener("DOMSubtreeModified", function () {
    document.querySelectorAll(".tree-item:not([tabindex])").forEach(function (el) {
      el.setAttribute("tabindex", "0");
      el.setAttribute("role", "treeitem");
    });
  });
})();
