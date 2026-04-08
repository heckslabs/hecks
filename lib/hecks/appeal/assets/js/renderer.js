// HecksAppeal IDE — HTML Builders (Core)
//
// Builds HTML strings from state data for sidebar, editor,
// diagrams, event rows, and status bar. Uses Tailwind CSS classes.
//
//   Usage:
//     HecksRenderer.renderSidebar(projects);
//     HecksRenderer.renderEditor("app.rb", "puts 'hi'");
//

(function () {
  "use strict";

  function escapeHtml(str) {
    if (!str) return "";
    var div = document.createElement("div");
    div.textContent = str;
    return div.innerHTML;
  }

  function renderSidebar(projects) {
    var container = document.getElementById("sidebar-content");
    if (!container) return;
    if (!projects || projects.length === 0) {
      container.innerHTML = '<p class="text-white/32 text-sm px-3 py-2">No projects loaded</p>';
      return;
    }
    var html = "";
    projects.forEach(function (project) {
      html += renderProjectTree(project);
    });
    container.innerHTML = html;
  }

  function renderProjectTree(project) {
    var html = '<div class="mb-2">';
    html += '<div class="tree-item flex items-center gap-1 px-3 py-1 text-white/87 text-sm cursor-pointer hover:bg-white/8 rounded" ';
    html += 'data-expandable="true" data-kind="project" role="treeitem" aria-expanded="true">';
    html += '<span class="icon text-white/54 text-xs">\u25BE</span>';
    html += '<span class="font-medium">' + escapeHtml(project.name) + '</span></div>';
    html += '<div class="tree-group pl-2">';
    if (project.files && project.files.length > 0) {
      html += renderFileGroup(project.files);
    }
    if (project.domains && project.domains.length > 0) {
      project.domains.forEach(function (domain) {
        html += renderDomainGroup(domain);
      });
    }
    html += '</div></div>';
    return html;
  }

  function renderFileGroup(files) {
    var html = '<div class="tree-item flex items-center gap-1 px-3 py-1 text-white/54 text-xs cursor-pointer hover:bg-white/8 rounded" ';
    html += 'data-expandable="true" role="treeitem" aria-expanded="true">';
    html += '<span class="icon text-xs">\u25BE</span><span>Files</span></div>';
    html += '<div class="tree-group pl-3">';
    files.forEach(function (file) {
      html += '<div class="tree-item flex items-center gap-1 px-3 py-1 text-white/87 text-sm cursor-pointer hover:bg-white/8 rounded" ';
      html += 'data-kind="file" data-path="' + escapeHtml(file.path) + '" role="treeitem">';
      html += '<span class="text-white/54 text-xs">\u2501</span>';
      html += '<span>' + escapeHtml(file.name) + '</span></div>';
    });
    html += '</div>';
    return html;
  }

  function renderDomainGroup(domain) {
    var html = '<div class="tree-item flex items-center gap-1 px-3 py-1 text-white/54 text-xs cursor-pointer hover:bg-white/8 rounded" ';
    html += 'data-expandable="true" role="treeitem" aria-expanded="false">';
    html += '<span class="icon text-xs">\u25B8</span>';
    html += '<span>' + escapeHtml(domain.name) + '</span></div>';
    html += '<div class="tree-group pl-3" hidden>';
    if (domain.aggregates) {
      domain.aggregates.forEach(function (agg) {
        html += renderAggregateItem(agg);
      });
    }
    if (domain.policies && domain.policies.length > 0) {
      html += renderPoliciesGroup(domain.policies);
    }
    html += '</div>';
    return html;
  }

  function renderAggregateItem(agg) {
    var html = '<div class="tree-item flex items-center gap-1 px-3 py-1 text-white/87 text-sm cursor-pointer hover:bg-white/8 rounded" ';
    html += 'data-kind="aggregate" data-aggregate="' + escapeHtml(agg.name) + '" role="treeitem">';
    html += '<span class="text-[#4361ee] text-xs">\u25C6</span>';
    html += '<span>' + escapeHtml(agg.name) + '</span></div>';
    return html;
  }

  function renderPoliciesGroup(policies) {
    var html = '<div class="tree-item flex items-center gap-1 px-3 py-1 text-white/54 text-xs cursor-pointer hover:bg-white/8 rounded" ';
    html += 'data-expandable="true" role="treeitem" aria-expanded="false">';
    html += '<span class="icon text-xs">\u25B8</span>';
    html += '<span>Policies</span></div>';
    html += '<div class="tree-group pl-3" hidden>';
    policies.forEach(function (p) {
      html += '<div class="tree-item flex items-center gap-1 px-3 py-1 text-white/87 text-sm cursor-pointer hover:bg-white/8 rounded" ';
      html += 'data-kind="policy" role="treeitem" title="on ' + escapeHtml(p.event) + ' \u2192 ' + escapeHtml(p.command) + '">';
      html += '<span class="text-amber-400 text-xs">\u26A1</span>';
      html += '<span>' + escapeHtml(p.name) + '</span>';
      html += '<span class="ml-auto text-white/32 text-[10px]">' + escapeHtml(p.event) + ' \u2192 ' + escapeHtml(p.command) + '</span>';
      html += '</div>';
    });
    html += '</div>';
    return html;
  }

  function renderEditor(filename, content) {
    var container = document.getElementById("editor-content");
    if (!container) return;
    if (!filename) {
      container.innerHTML = '<p class="text-white/32 text-sm p-4">No file open</p>';
      return;
    }
    var lines = (content || "").split("\n");
    var html = '<div class="bg-[#0d0d0d] rounded p-2">';
    html += '<div class="flex items-center gap-2 px-3 py-1 mb-2 border-b border-white/12">';
    html += '<span class="text-white/87 text-sm font-mono">' + escapeHtml(filename) + '</span></div>';
    html += '<pre class="font-mono text-sm leading-relaxed overflow-x-auto" role="code">';
    lines.forEach(function (line, i) {
      var num = '<span class="inline-block w-8 text-right text-white/32 mr-4 select-none">' + (i + 1) + '</span>';
      html += num + '<span class="text-white/87">' + escapeHtml(line) + '</span>\n';
    });
    html += '</pre></div>';
    container.innerHTML = html;
  }

  function renderDiagrams(diagrams) {
    var container = document.getElementById("diagrams-content");
    if (!container) return;
    var types = [
      { key: "structure", label: "Structure" },
      { key: "behavior", label: "Behavior" },
      { key: "flow", label: "Flow" }
    ];
    var html = "";
    types.forEach(function (t) {
      var data = diagrams[t.key];
      html += '<div class="mb-4">';
      html += '<div class="flex items-center justify-between mb-2">';
      html += '<h3 class="text-white/87 text-sm font-medium">' + t.label + '</h3>';
      if (data) {
        html += '<div class="flex items-center gap-1">';
        html += '<button class="zoom-btn px-1.5 py-0.5 text-xs text-white/54 hover:text-white/87 hover:bg-white/8 rounded" data-zoom-target="' + t.key + '" data-zoom="-1" aria-label="Zoom out">−</button>';
        html += '<span class="zoom-level text-xs text-white/38 w-8 text-center" data-zoom-label="' + t.key + '">100%</span>';
        html += '<button class="zoom-btn px-1.5 py-0.5 text-xs text-white/54 hover:text-white/87 hover:bg-white/8 rounded" data-zoom-target="' + t.key + '" data-zoom="1" aria-label="Zoom in">+</button>';
        html += '<button class="zoom-btn px-1.5 py-0.5 text-xs text-white/54 hover:text-white/87 hover:bg-white/8 rounded" data-zoom-target="' + t.key + '" data-zoom="0" aria-label="Reset zoom">⟲</button>';
        html += '</div>';
      }
      html += '</div>';
      if (data) {
        html += '<div class="diagram-viewport overflow-auto bg-[#1a1a2e] rounded border border-white/[.12]" data-diagram="' + t.key + '">';
        html += '<pre class="mermaid p-3" role="img" aria-label="' + t.label + ' diagram">';
        html += data + '</pre>';
        html += '</div>';
      } else {
        html += '<p class="text-white/32 text-sm">No ' + t.label.toLowerCase() + ' diagram</p>';
      }
      html += '</div>';
    });
    container.innerHTML = html;
    diagramZoomState = {};
    if (typeof mermaid !== "undefined" && mermaid.run) {
      mermaid.run({ querySelector: ".mermaid" }).then(function () {
        bindDiagramZoom(container);
      }).catch(function (err) {
        console.error("[Mermaid] " + err.message);
        bindDiagramZoom(container);
      });
    }
  }

  var diagramZoomState = {};

  function setDiagramZoom(key, level) {
    level = Math.max(0.25, Math.min(5, level));
    var vp = document.querySelector('[data-diagram="' + key + '"]');
    if (!vp) return;
    var svg = vp.querySelector("svg");
    if (!svg) return;
    var state = diagramZoomState[key];
    if (!state) {
      var w = parseFloat(svg.getAttribute("width")) || svg.viewBox.baseVal.width || svg.getBoundingClientRect().width;
      var h = parseFloat(svg.getAttribute("height")) || svg.viewBox.baseVal.height || svg.getBoundingClientRect().height;
      state = { origW: w, origH: h };
      diagramZoomState[key] = state;
    }
    svg.setAttribute("width", state.origW * level);
    svg.setAttribute("height", state.origH * level);
    diagramZoomState[key].level = level;
    var label = document.querySelector('[data-zoom-label="' + key + '"]');
    if (label) label.textContent = Math.round(level * 100) + "%";
  }

  function bindDiagramZoom(container) {
    container.querySelectorAll(".zoom-btn").forEach(function (btn) {
      btn.addEventListener("click", function () {
        var key = btn.dataset.zoomTarget;
        var dir = parseInt(btn.dataset.zoom, 10);
        var current = (diagramZoomState[key] && diagramZoomState[key].level) || 1;
        if (dir === 0) { setDiagramZoom(key, 1); return; }
        setDiagramZoom(key, current + dir * 0.25);
      });
    });
    container.querySelectorAll(".diagram-viewport").forEach(function (vp) {
      vp.addEventListener("wheel", function (e) {
        if (!e.ctrlKey && !e.metaKey) return;
        e.preventDefault();
        var key = vp.dataset.diagram;
        var current = (diagramZoomState[key] && diagramZoomState[key].level) || 1;
        var delta = e.deltaY > 0 ? -0.15 : 0.15;
        setDiagramZoom(key, current + delta);
      }, { passive: false });
    });
  }

  function renderEventRow(eventData) {
    var name = escapeHtml(eventData.event || eventData.name || "Unknown");
    var agg = escapeHtml(eventData.aggregate || "");
    var time = eventData.timestamp || new Date().toLocaleTimeString();
    var html = '<div class="event-row">';
    html += '<div class="flex items-center gap-2 px-3 py-1 text-sm hover:bg-white/[.04] cursor-pointer select-none" role="listitem" data-action="toggle-event-detail">';
    html += '<span class="event-arrow text-white/32 text-xs flex-shrink-0">\u25B8</span>';
    html += '<span class="w-2 h-2 rounded-full bg-[#4361ee] flex-shrink-0" aria-hidden="true"></span>';
    var label = name;
    if (eventData.data) {
      var d = eventData.data;
      if (d.filename) label += ' — ' + escapeHtml(d.filename);
      else if (d.path) label += ' — ' + escapeHtml(d.path);
      else if (d.name) label += ' — ' + escapeHtml(d.name);
      else if (d.tab) label += ' — ' + escapeHtml(d.tab);
      else if (d.query) label += ' — ' + escapeHtml(d.query);
    }
    html += '<span class="text-white/87 flex-1">' + label + '</span>';
    html += '<span class="text-white/54 text-xs">' + agg + '</span>';
    html += '<span class="text-white/32 text-xs ml-auto">' + escapeHtml(time) + '</span>';
    html += '</div>';
    html += '<div class="event-detail hidden px-3 py-1.5 ml-7 mb-1 text-xs bg-white/[.02] rounded border-l-2 border-[#4361ee]/40">';
    html += renderEventDetail(eventData);
    html += '</div>';
    html += '</div>';
    return html;
  }

  function renderEventDetail(eventData) {
    var data = eventData.data;
    if (!data || (typeof data === "object" && Object.keys(data).length === 0)) {
      return '<span class="text-white/32 italic">No additional data</span>';
    }
    var html = '';
    if (typeof data === "object") {
      Object.keys(data).forEach(function (key) {
        var val = data[key];
        var str = (typeof val === "object") ? JSON.stringify(val, null, 2) : String(val);
        var display = escapeHtml(str.length > 200 ? str.substring(0, 200) + "..." : str);
        html += '<div class="flex gap-2 py-0.5">';
        html += '<span class="text-[#4361ee] font-medium min-w-[80px]">' + escapeHtml(key) + '</span>';
        if (typeof val === "object") {
          html += '<pre class="text-white/60 whitespace-pre-wrap">' + escapeHtml(display) + '</pre>';
        } else {
          html += '<span class="text-white/60">' + display + '</span>';
        }
        html += '</div>';
      });
    } else {
      html += '<span class="text-white/60">' + escapeHtml(String(data)) + '</span>';
    }
    return html;
  }

  function renderStatus(status) {
    var container = document.getElementById("status-bar");
    if (!container) return;
    var dotColor = status.connected ? "bg-green-500" : "bg-red-500";
    var label = status.connected ? "Connected" : "Disconnected";
    var html = '<div class="flex items-center gap-4 px-3 py-1 text-xs">';
    html += '<div id="connection-status" class="flex items-center gap-1" role="status" aria-label="Connection status">';
    html += '<span class="w-2 h-2 rounded-full ' + dotColor + '" aria-hidden="true"></span>';
    html += '<span class="text-white/54">' + label + '</span></div>';
    html += '<span id="domain-count" class="text-white/54">' + (status.domains || 0) + ' domains</span>';
    html += '<span id="aggregate-count" class="text-white/54">' + (status.aggregates || 0) + ' aggregates</span>';
    html += '</div>';
    container.innerHTML = html;
  }

  window.HecksRenderer = {
    renderSidebar: renderSidebar,
    renderEditor: renderEditor,
    renderDiagrams: renderDiagrams,
    renderEventRow: renderEventRow,
    renderStatus: renderStatus,
    escapeHtml: escapeHtml
  };
})();
