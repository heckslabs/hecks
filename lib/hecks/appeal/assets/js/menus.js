// HecksAppeal IDE — Menu System
//
// All menu actions dispatch through Hecks.dispatch() to the domain.
// Menu, Layout, Project, Diagram, Explorer, Glossary — all UL.
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

  function setupMenus() {
    document.addEventListener("click", function (e) {
      var menuBtn = e.target.closest("[data-menu]");
      if (menuBtn) {
        var dropdown = menuBtn.nextElementSibling;
        if (!dropdown) return;
        var wasOpen = !dropdown.hidden;

        closeAllMenus();

        if (!wasOpen) {
          dropdown.hidden = false;
          menuBtn.setAttribute("aria-expanded", "true");
          dispatch("Menu", "OpenMenu", { menu_name: menuBtn.dataset.menu });
        } else {
          dispatch("Menu", "CloseMenu");
        }
        return;
      }

      var menuItem = e.target.closest("[data-menu-action]");
      if (menuItem) {
        closeAllMenus();
        dispatchMenuAction(menuItem.dataset.menuAction);
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
      dispatch("Menu", "CloseMenu");
    }
  }

  function dispatchMenuAction(action) {
    switch (action) {
      case "open-project":
        dispatch("Project", "DiscoverProjects", { path: "." });
        break;
      case "refresh-projects":
        dispatch("Project", "DiscoverProjects", { path: "." });
        break;
      case "close-project":
        dispatch("Project", "CloseProject");
        break;
      case "focus-editor":
        dispatch("Layout", "SelectTab", { tab_name: "editor" });
        break;
      case "focus-diagrams":
        dispatch("Layout", "SelectTab", { tab_name: "diagrams" });
        break;
      case "focus-console":
        dispatch("Layout", "SelectTab", { tab_name: "console" });
        break;
      case "view-all-diagrams":
        dispatch("Diagram", "GenerateDiagram", { view_type: "all" });
        break;
      case "run-analysis":
        dispatch("Diagram", "RunAnalysis");
        break;
      case "export-bluebook":
        dispatch("Explorer", "ExportBluebook", { format: "bluebook" });
        break;
      case "view-glossary":
        dispatch("Glossary", "ShowGlossary");
        break;
      case "hide-projects":
        dispatch("Layout", "HideProjects");
        break;
      case "show-projects":
        dispatch("Layout", "ShowProjects");
        break;
    }
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", setupMenus);
  } else {
    setupMenus();
  }
})();
