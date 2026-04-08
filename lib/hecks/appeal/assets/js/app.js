// HecksAppeal IDE — Application State Manager
//
// Central state store for the IDE. Receives events from the
// server, updates state, and triggers re-renders of affected panels.
//
//   State shape:
//     { projects: [], layout: {sidebar, events, tab, projectsHidden},
//       events: [], agent: {messages: []}, search: {results: []} }
//
//   Usage:
//     HecksApp.handleEvent({ event: "SidebarToggled", data: { collapsed: true } });
//     HecksApp.state.layout.sidebarCollapsed; // => true
//

(function () {
  "use strict";

  var state = {
    projects: [],
    layout: {
      sidebarCollapsed: false,
      eventsCollapsed: false,
      activeTab: "diagrams",
      projectsHidden: false,
      menuOpen: null
    },
    events: [],
    agent: { messages: [] },
    search: { query: "", results: [] },
    editor: { filename: null, content: null },
    diagrams: { structure: null, behavior: null, flow: null },
    console: { aggregates: [], selectedAggregate: null, selectedCommand: null },
    status: { connected: false, domains: 0, aggregates: 0 },
    world: null,
    cwd: "",
    screenshotCount: 0
  };

  function handleEvent(event) {
    var R = window.HecksRenderer;
    switch (event.event) {
      case "StateLoaded":
        mergeState(event.data);
        fullRender();
        break;
      case "ProjectsDiscovered":
        state.projects = event.data.projects;
        R.renderSidebar(state.projects);
        R.renderStatus(state.status);
        break;
      case "ProjectOpened":
        state.projects = event.data.projects || state.projects;
        R.renderSidebar(state.projects);
        break;
      case "ProjectClosed":
        state.projects = event.data.projects || [];
        R.renderSidebar(state.projects);
        break;
      case "SidebarToggled":
        state.layout.sidebarCollapsed = event.data.sidebar_collapsed;
        togglePanel("sidebar", event.data.sidebar_collapsed);
        break;
      case "EventsPanelToggled":
        state.layout.eventsCollapsed = event.data.events_collapsed;
        togglePanel("events-panel", event.data.events_collapsed);
        break;
      case "ProjectsHidden":
        state.layout.projectsHidden = event.data.projects_hidden;
        togglePanel("sidebar-content", event.data.projects_hidden);
        break;
      case "ProjectsShown":
        state.layout.projectsHidden = event.data.projects_hidden;
        togglePanel("sidebar-content", event.data.projects_hidden);
        break;
      case "TabSelected":
        var tab = event.data.tab || event.data.active_tab;
        state.layout.activeTab = tab;
        activateTab(tab);
        break;
      case "PanelOpened":
        togglePanel(event.data.panel, false);
        break;
      case "PanelClosed":
        togglePanel(event.data.panel, true);
        break;
      case "FileOpened":
        state.editor.filename = event.data.filename;
        state.editor.content = event.data.content;
        R.renderEditor(event.data.filename, event.data.content);
        break;
      case "DiagramsGenerated":
      case "BluebookOverviewGenerated":
        state.diagrams = event.data;
        R.renderDiagrams(event.data);
        break;
      case "CommandSelected":
        state.console.selectedAggregate = event.data.aggregate_name;
        state.console.selectedCommand = event.data.command_name;
        R.renderConsole(state.console.aggregates, event.data.aggregate_name, event.data.command_name);
        break;
      case "CommandExecuted":
        appendEvent(event.data);
        break;
      case "EventReceived":
        appendEvent(event.data);
        break;
      case "AgentMessageReceived":
        state.agent.messages.push(event.data);
        R.renderAgentMessage(event.data.role, event.data.content);
        break;
      case "AgentThinking":
        state.agent.thinking = event.data.thinking;
        R.renderAgentThinking(event.data.thinking);
        break;
      case "AgentAdapterChanged":
        state.agent.mode = event.data.mode;
        break;
      case "SearchCompleted":
        state.search.results = event.data.results;
        state.search.query = event.data.query || "";
        break;
      case "SearchCleared":
        state.search.results = [];
        state.search.query = "";
        break;
      case "MenuOpened":
        state.layout.menuOpen = event.data.menu;
        break;
      case "MenuClosed":
        state.layout.menuOpen = null;
        break;
      case "ScreenshotCaptured":
        window.HecksStatus.flashScreenshot(state);
        break;
    }

    if (event.event && event.event !== "StateLoaded" && event.event !== "ScreenshotCaptured") {
      appendEvent({ event: event.event, aggregate: event.aggregate, timestamp: new Date().toLocaleTimeString(), data: event.data });
    }
  }

  function mergeState(data) {
    if (data.projects) state.projects = data.projects;
    if (data.layout) Object.assign(state.layout, data.layout);
    if (data.world) state.world = data.world;
    if (data.events) state.events = data.events;
    if (data.agent) Object.assign(state.agent, data.agent);
    if (data.editor) Object.assign(state.editor, data.editor);
    if (data.diagrams) Object.assign(state.diagrams, data.diagrams);
    if (data.console) Object.assign(state.console, data.console);
    if (data.status) Object.assign(state.status, data.status);
    if (data.cwd) state.cwd = data.cwd;

    // Default agent mode from world config
    if (state.world && state.world.configs && state.world.configs.claude) {
      state.agent.mode = state.agent.mode || "live";
    }
  }

  function fullRender() {
    var R = window.HecksRenderer;
    R.renderSidebar(state.projects);
    R.renderStatus(state.status);
    if (state.editor.filename) R.renderEditor(state.editor.filename, state.editor.content);
    if (state.diagrams.structure) R.renderDiagrams(state.diagrams);
    R.renderConsole(state.console.aggregates, state.console.selectedAggregate, state.console.selectedCommand);
    if (state.cwd) {
      var cwdEl = document.getElementById("cwd-path");
      if (cwdEl) cwdEl.textContent = state.cwd;
    }
    if (window.HecksCommandTester) window.HecksCommandTester.render();
    if (!state.agent.mode && state.world && state.world.configs && state.world.configs.claude) {
      state.agent.mode = "live";
    }
  }

  function appendEvent(eventData) {
    state.events.unshift(eventData);
    var R = window.HecksRenderer;
    var container = document.getElementById("events-content");
    if (container) {
      container.insertAdjacentHTML("afterbegin", R.renderEventRow(eventData));
    }
  }

  function togglePanel(id, collapsed) {
    var el = document.getElementById(id);
    if (!el) return;
    el.style.display = collapsed ? "none" : "";
    if (id === "sidebar") {
      var expand = document.getElementById("sidebar-expand");
      if (expand) expand.style.display = collapsed ? "" : "none";
    }
  }

  function activateTab(name) {
    var tabs = document.querySelectorAll("[data-tab]");
    tabs.forEach(function (t) {
      var isActive = t.dataset.tab === name;
      t.setAttribute("aria-selected", isActive ? "true" : "false");
      t.classList.toggle("text-white/[.87]", isActive);
      t.classList.toggle("border-accent", isActive);
      t.classList.toggle("bg-white/[.04]", isActive);
      t.classList.toggle("text-white/[.54]", !isActive);
      t.classList.toggle("border-transparent", !isActive);
      var panel = document.getElementById(t.getAttribute("aria-controls"));
      if (panel) panel.style.display = isActive ? "" : "none";
    });
  }

  window.HecksApp = { state: state, handleEvent: handleEvent, getState: function() { return state; } };
})();
