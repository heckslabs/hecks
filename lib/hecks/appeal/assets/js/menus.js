// HecksAppeal IDE — Menu Dropdown Behavior
//
// Handles opening/closing dropdown menus in the menu bar,
// dispatching menu actions as domain commands via HecksIDE.command().
//
//   Requires window.HecksIDE.command() from socket.js
//
//   Usage:
//     <button data-menu="file">File</button>
//     <div class="menu-dropdown-content" hidden>
//       <div data-menu-action="open-project">Open</div>
//     </div>
//

(function () {
  "use strict";

  function setupMenus() {
    document.addEventListener("click", function (e) {
      var menuBtn = e.target.closest("[data-menu]");
      if (menuBtn) {
        e.stopPropagation();
        var dropdown = menuBtn.nextElementSibling;
        var wasOpen = !dropdown.hidden;

        closeAllMenus();

        if (!wasOpen) {
          dropdown.hidden = false;
          menuBtn.setAttribute("aria-expanded", "true");
          window.HecksIDE.command("Menu", "OpenMenu", { menu: menuBtn.dataset.menu });
        } else {
          window.HecksIDE.command("Menu", "CloseMenu", {});
        }
        return;
      }

      var menuItem = e.target.closest("[data-menu-action]");
      if (menuItem) {
        var menuAction = menuItem.dataset.menuAction;
        closeAllMenus();
        dispatchMenuAction(menuAction);
        return;
      }

      closeAllMenus(true);
    });

    document.addEventListener("keydown", function (e) {
      if (e.key === "Escape") closeAllMenus(true);
    });
  }

  function closeAllMenus(sendCommand) {
    var wasOpen = false;
    document.querySelectorAll("[data-menu] + [role='menu']").forEach(function (dd) {
      if (!dd.hidden) wasOpen = true;
      dd.hidden = true;
    });
    document.querySelectorAll("[data-menu]").forEach(function (btn) {
      btn.setAttribute("aria-expanded", "false");
    });
    if (sendCommand && wasOpen) {
      window.HecksIDE.command("Menu", "CloseMenu", {});
    }
  }

  function dispatchMenuAction(menuAction) {
    var cmd = window.HecksIDE.command;

    switch (menuAction) {
      case "open-project":
        cmd("Project", "DiscoverProjects", { path: "." });
        break;
      case "refresh-projects":
        cmd("Project", "DiscoverProjects", { path: "." });
        break;
      case "close-project":
        cmd("Project", "CloseProject", {});
        break;
      case "focus-editor":
        cmd("Layout", "SelectTab", { tab: "editor" });
        break;
      case "focus-diagrams":
        cmd("Layout", "SelectTab", { tab: "diagrams" });
        break;
      case "focus-console":
        cmd("Layout", "SelectTab", { tab: "console" });
        break;
      case "view-all-diagrams":
        cmd("Diagram", "GenerateDiagram", { view_type: "all" });
        break;
      case "run-analysis":
        cmd("Insight", "AnalyzeDomain", {});
        break;
      case "export-bluebook":
        cmd("Explorer", "LoadDomain", {});
        break;
      case "view-glossary":
        cmd("Glossary", "GenerateGlossary", {});
        break;
      case "hide-projects":
        cmd("Layout", "HideProjects", {});
        break;
      case "show-projects":
        cmd("Layout", "ShowProjects", {});
        break;
    }
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", setupMenus);
  } else {
    setupMenus();
  }
})();
