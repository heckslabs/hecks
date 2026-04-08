// HecksAppeal IDE — Keyboard Navigation & Shortcuts
//
// Full keyboard accessibility:
//   Tab / Shift+Tab — move between panels
//   Arrow keys — navigate tree items, tabs
//   Enter / Space — activate focused element
//   Escape — close panels, clear focus
//   Ctrl+P / Cmd+P — focus search (future)
//   Ctrl+` / Cmd+` — toggle events panel
//

(function () {
  "use strict";

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

    // Ctrl/Cmd + ` — toggle events panel
    if (mod && e.key === "`") {
      e.preventDefault();
      var events = document.getElementById("events-panel");
      if (events) events.classList.toggle("collapsed");
    }

    // Escape — blur active element, close expanded panels
    if (e.key === "Escape") {
      if (document.activeElement && document.activeElement !== document.body) {
        document.activeElement.blur();
      }
    }

    // Ctrl/Cmd + 1/2/3 — switch tabs
    if (mod && e.key >= "1" && e.key <= "3") {
      e.preventDefault();
      var tabs = document.querySelectorAll("[role='tab']");
      var idx = parseInt(e.key) - 1;
      if (tabs[idx]) {
        tabs[idx].focus();
        tabs[idx].click();
      }
    }
  });

  // ── Focus Management ────────────────────────────────────────

  // Make tree items focusable
  document.addEventListener("DOMSubtreeModified", function () {
    document.querySelectorAll(".tree-item:not([tabindex])").forEach(function (el) {
      el.setAttribute("tabindex", "0");
      el.setAttribute("role", "treeitem");
    });
  });
})();
