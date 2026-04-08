// HecksAppeal IDE — Application State Manager
//
// Receives domain events (from server or client dispatch),
// updates state, and triggers rendering. State is the domain.
// Rendering is the adapter. This file bridges the two.
//
//   State updates: domain-driven, from Hecks.dispatch events
//   Rendering: adapter-specific, delegates to HecksRenderer
//

(function () {
  "use strict";

  var state = {
    projects: [],
    layout: {
      sidebarCollapsed: false,
      eventsCollapsed: false,
      activeTab: "agent",
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

  // -- Event Handler: update state, then render --

  function handleEvent(event) {
    updateState(event);
    render(event);
    recordEvent(event);
  }

  // -- State updates (domain logic — portable to any platform) --

  function updateState(event) {
    var d = event.data || {};
    switch (event.event) {
      case "StateLoaded":
        mergeState(d);
        break;
      case "ProjectsDiscovered":
      case "ProjectOpened":
        if (d.projects) state.projects = d.projects;
        break;
      case "ProjectClosed":
        state.projects = d.projects || [];
        break;
      case "SidebarToggled":
        state.layout.sidebarCollapsed = d.sidebar_collapsed;
        break;
      case "EventsPanelToggled":
        state.layout.eventsCollapsed = d.events_collapsed;
        break;
      case "ProjectsHidden":
      case "ProjectsShown":
        state.layout.projectsHidden = d.projects_hidden;
        break;
      case "TabSelected":
        state.layout.activeTab = d.tab || d.tab_name || d.active_tab;
        break;
      case "FileOpened":
        state.editor.filename = d.filename;
        state.editor.content = d.content;
        break;
      case "DiagramsGenerated":
      case "BluebookOverviewGenerated":
        state.diagrams = d;
        break;
      case "CommandSelected":
        state.console.selectedAggregate = d.aggregate_name;
        state.console.selectedCommand = d.command_name;
        break;
      case "AgentMessageReceived":
        state.agent.messages.push(d);
        break;
      case "AgentThinking":
        state.agent.thinking = d.thinking;
        break;
      case "AgentAdapterChanged":
        state.agent.mode = d.mode;
        break;
      case "SearchCompleted":
        state.search.results = d.results;
        state.search.query = d.query || "";
        break;
      case "SearchCleared":
        state.search.results = [];
        state.search.query = "";
        break;
      case "MenuOpened":
        state.layout.menuOpen = d.menu || d.menu_name;
        break;
      case "MenuClosed":
        state.layout.menuOpen = null;
        break;
      case "AggregateInspected":
        state.editor.aggregate = findAggregate(state.projects, d.aggregate_name);
        state.editor.filename = null;
        state.editor.content = null;
        state.layout.activeTab = "editor";
        break;
      case "FeatureCreated":
      case "FeaturePlanned":
      case "AdditionsVerified":
      case "FeatureCompleted":
        if (window.HecksFeatures) window.HecksFeatures.handleEvent(event);
        break;
    }
  }

  // -- Rendering (adapter-specific — HTML/CSS, would differ on iOS/desktop) --

  function render(event) {
    var R = window.HecksRenderer;
    if (!R) return;
    var d = event.data || {};

    switch (event.event) {
      case "StateLoaded":
        fullRender();
        break;
      case "ProjectsDiscovered":
      case "ProjectOpened":
      case "ProjectClosed":
        R.renderSidebar(state.projects);
        R.renderStatus(state.status);
        renderConsoleForms(R);
        break;
      case "SidebarToggled":
        togglePanel("sidebar", state.layout.sidebarCollapsed);
        break;
      case "EventsPanelToggled":
        togglePanel("events-panel", state.layout.eventsCollapsed);
        break;
      case "ProjectsHidden":
      case "ProjectsShown":
        togglePanel("sidebar-content", state.layout.projectsHidden);
        break;
      case "TabSelected":
        activateTab(state.layout.activeTab);
        if (state.layout.activeTab === "console") renderConsoleForms(R);
        break;
      case "PanelOpened":
        togglePanel(d.panel, false);
        break;
      case "PanelClosed":
        togglePanel(d.panel, true);
        break;
      case "FileOpened":
        R.renderEditor(d.filename, d.content);
        break;
      case "DiagramsGenerated":
      case "BluebookOverviewGenerated":
        R.renderDiagrams(d);
        break;
      case "CommandSelected":
        renderConsoleForms(R);
        break;
      case "AgentMessageReceived":
        R.renderAgentMessage(d.role, d.content);
        break;
      case "AgentThinking":
        R.renderAgentThinking(d.thinking);
        break;
      case "AggregateInspected":
        if (R.renderAggregateDetail) R.renderAggregateDetail(state.editor.aggregate);
        activateTab("editor");
        break;
      case "FeatureCreated":
      case "FeaturePlanned":
      case "AdditionsVerified":
      case "FeatureCompleted":
        break;
    }
  }

  // -- Record events in the event panel --

  function recordEvent(event) {
    if (event.event && event.event !== "StateLoaded" && event.event !== "ScreenshotCaptured") {
      state.events.unshift({
        event: event.event, aggregate: event.aggregate,
        timestamp: new Date().toLocaleTimeString(), data: event.data
      });
      var R = window.HecksRenderer;
      var container = document.getElementById("events-content");
      if (R && container) {
        container.insertAdjacentHTML("afterbegin", R.renderEventRow(state.events[0]));
      }
    }
  }

  function findAggregate(projects, name) {
    if (!projects || !name) return null;
    for (var i = 0; i < projects.length; i++) {
      var domains = projects[i].domains || [];
      for (var j = 0; j < domains.length; j++) {
        var aggs = domains[j].aggregates || [];
        for (var k = 0; k < aggs.length; k++) {
          if (aggs[k].name === name) return aggs[k];
        }
      }
    }
    return null;
  }

  // -- State merge (initial load) --

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
    if (state.world && state.world.configs && state.world.configs.claude && !state.agent.mode) {
      state.agent.mode = "live";
    }
  }

  // -- Full render (on initial state load) --

  function fullRender() {
    var R = window.HecksRenderer;
    if (!R) return;
    R.renderSidebar(state.projects);
    R.renderStatus(state.status);
    if (state.editor.aggregate && R.renderAggregateDetail) R.renderAggregateDetail(state.editor.aggregate);
    else if (state.editor.filename) R.renderEditor(state.editor.filename, state.editor.content);
    if (state.diagrams.structure) R.renderDiagrams(state.diagrams);
    renderConsoleForms(R);
    if (state.cwd) {
      var cwdEl = document.getElementById("cwd-path");
      if (cwdEl) cwdEl.textContent = state.cwd;
    }
    if (state.layout.activeTab) activateTab(state.layout.activeTab);
    if (window.HecksCommandTester) window.HecksCommandTester.render();
  }

  // -- Adapter helpers (HTML-specific rendering) --

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

  function renderConsoleForms(R) {
    if (!R || !R.renderCommandForms) return;
    var domain = null;
    if (state.projects.length > 0 && state.projects[0].domains && state.projects[0].domains.length > 0) {
      domain = state.projects[0].domains[0];
    }
    R.renderCommandForms(domain);
  }

  window.HecksApp = { state: state, handleEvent: handleEvent, getState: function() { return state; } };
})();
