// HecksAppeal IDE — Aggregate Detail Renderer
//
// Renders full aggregate inspection view in the editor panel:
// header, attributes table, commands with run buttons, value
// objects, references, lifecycle flow, queries, and policies.
//
//   Usage:
//     HecksRenderer.renderAggregateDetail(aggregate);
//

(function () {
  "use strict";

  var R = window.HecksRenderer;
  var esc = R.escapeHtml;

  function renderAggregateDetail(agg) {
    var container = document.getElementById("editor-content");
    if (!container || !agg) return;
    var html = '<div class="space-y-6 p-4 max-w-4xl">';
    html += sectionHeader(agg);
    html += sectionAttributes(agg.attributes);
    html += sectionCommands(agg.commands);
    html += sectionValueObjects(agg.value_objects);
    html += sectionReferences(agg.references_to);
    html += sectionLifecycle(agg.lifecycle);
    html += sectionQueries(agg.queries);
    html += sectionPolicies(agg.policies);
    html += '</div>';
    container.innerHTML = html;
  }

  function sectionHeader(agg) {
    var html = '<div class="border-b border-white/12 pb-4">';
    html += '<div class="flex items-center gap-3">';
    html += '<span class="text-[#4361ee] text-2xl">\u25C6</span>';
    html += '<h1 class="text-white/[.87] text-2xl font-bold">' + esc(agg.name) + '</h1>';
    if (agg.domain) {
      html += '<span class="text-white/38 text-sm bg-white/8 px-2 py-0.5 rounded">' + esc(agg.domain) + '</span>';
    }
    html += '</div>';
    if (agg.description) {
      html += '<p class="text-white/54 text-sm mt-2">' + esc(agg.description) + '</p>';
    }
    html += '</div>';
    return html;
  }

  function sectionAttributes(attrs) {
    if (!attrs || attrs.length === 0) return "";
    var html = '<div>';
    html += heading("Attributes");
    html += '<table class="w-full text-sm border border-white/8 rounded overflow-hidden">';
    html += '<thead><tr class="bg-white/[.04]">';
    html += '<th class="text-left text-white/54 px-3 py-2 font-medium">Name</th>';
    html += '<th class="text-left text-white/54 px-3 py-2 font-medium">Type</th>';
    html += '<th class="text-left text-white/54 px-3 py-2 font-medium">Default</th>';
    html += '</tr></thead><tbody>';
    attrs.forEach(function (a) {
      html += '<tr class="border-t border-white/8 hover:bg-white/[.02]">';
      html += '<td class="text-white/87 px-3 py-1.5 font-mono text-xs">' + esc(a.name) + '</td>';
      html += '<td class="text-[#4361ee] px-3 py-1.5 font-mono text-xs">' + esc(a.type) + '</td>';
      html += '<td class="text-white/38 px-3 py-1.5 text-xs">' + esc(a.default || "\u2014") + '</td>';
      html += '</tr>';
    });
    html += '</tbody></table></div>';
    return html;
  }

  function sectionCommands(cmds) {
    if (!cmds || cmds.length === 0) return "";
    var html = '<div>';
    html += heading("Commands");
    html += '<div class="space-y-3">';
    cmds.forEach(function (cmd) {
      html += '<div class="bg-white/[.02] border border-white/8 rounded-lg p-3">';
      html += '<div class="flex items-center justify-between mb-2">';
      html += '<span class="text-white/87 font-medium text-sm">' + esc(cmd.name) + '</span>';
      html += '<button class="bg-[#4361ee] hover:bg-[#5a7df7] text-white text-xs px-3 py-1 rounded transition-colors" ';
      html += 'data-run-command="' + esc(cmd.name) + '">Run</button></div>';
      if (cmd.attributes && cmd.attributes.length > 0) {
        html += '<div class="space-y-1 mb-2">';
        cmd.attributes.forEach(function (a) {
          html += '<div class="flex gap-2 text-xs">';
          html += '<span class="text-white/54 font-mono">' + esc(a.name) + '</span>';
          html += '<span class="text-[#4361ee]/70 font-mono">' + esc(a.type) + '</span>';
          html += '</div>';
        });
        html += '</div>';
      }
      if (cmd.events && cmd.events.length > 0) {
        html += '<div class="text-xs text-white/38 mt-1">emits: ';
        html += cmd.events.map(function (e) { return '<span class="text-amber-400/70">' + esc(e) + '</span>'; }).join(", ");
        html += '</div>';
      }
      html += '</div>';
    });
    html += '</div></div>';
    return html;
  }

  function sectionValueObjects(vos) {
    if (!vos || vos.length === 0) return "";
    var html = '<div>';
    html += heading("Value Objects");
    html += '<div class="grid gap-2">';
    vos.forEach(function (vo) {
      html += '<div class="bg-white/[.02] border border-white/8 rounded p-3">';
      html += '<span class="text-white/87 text-sm font-medium">' + esc(vo.name) + '</span>';
      if (vo.attributes && vo.attributes.length > 0) {
        html += '<div class="mt-1 space-y-0.5">';
        vo.attributes.forEach(function (a) {
          html += '<div class="text-xs"><span class="text-white/54 font-mono">' + esc(a.name) + '</span>';
          html += ' <span class="text-[#4361ee]/70 font-mono">' + esc(a.type) + '</span></div>';
        });
        html += '</div>';
      }
      if (vo.invariants && vo.invariants.length > 0) {
        html += '<div class="mt-1 text-xs text-amber-400/60">invariants: ' + vo.invariants.map(esc).join(", ") + '</div>';
      }
      html += '</div>';
    });
    html += '</div></div>';
    return html;
  }

  function sectionReferences(refs) {
    if (!refs || refs.length === 0) return "";
    var html = '<div>';
    html += heading("References");
    html += '<div class="flex flex-wrap gap-2">';
    refs.forEach(function (ref) {
      html += '<div class="bg-[#16213e] border border-[#4361ee]/20 rounded-lg px-3 py-2 text-sm">';
      html += '<span class="text-white/87">' + esc(ref.name || ref.type) + '</span>';
      if (ref.kind) html += ' <span class="text-white/38 text-xs">(' + esc(ref.kind) + ')</span>';
      if (ref.domain) html += ' <span class="text-[#4361ee]/60 text-xs">' + esc(ref.domain) + '</span>';
      html += '</div>';
    });
    html += '</div></div>';
    return html;
  }

  function sectionLifecycle(lc) {
    if (!lc) return "";
    var html = '<div>';
    html += heading("Lifecycle");
    html += '<div class="bg-white/[.02] border border-white/8 rounded-lg p-4">';
    html += '<div class="text-xs text-white/38 mb-3">field: <span class="text-white/54 font-mono">' + esc(lc.field) + '</span>';
    if (lc.default) html += ' &middot; default: <span class="text-white/54 font-mono">' + esc(lc.default) + '</span>';
    html += '</div>';
    if (lc.states && lc.states.length > 0) {
      html += '<div class="flex flex-wrap items-center gap-2 mb-4">';
      lc.states.forEach(function (s, i) {
        var isDefault = s === lc.default;
        var cls = isDefault ? "bg-[#4361ee] text-white" : "bg-white/8 text-white/70";
        html += '<div class="' + cls + ' px-3 py-1.5 rounded-full text-xs font-medium">' + esc(s) + '</div>';
        if (i < lc.states.length - 1) html += '<span class="text-white/20">\u2014</span>';
      });
      html += '</div>';
    }
    if (lc.transitions && lc.transitions.length > 0) {
      html += '<div class="space-y-2">';
      lc.transitions.forEach(function (t) {
        html += '<div class="flex items-center gap-2 text-xs">';
        var fromStates = t.from ? (Array.isArray(t.from) ? t.from : [t.from]) : ["*"];
        html += '<span class="text-white/54 font-mono">' + fromStates.map(esc).join(", ") + '</span>';
        html += '<span class="text-[#4361ee]">\u2192</span>';
        html += '<span class="text-white/87 font-mono">' + esc(t.target) + '</span>';
        html += '<span class="text-white/38 ml-2">via</span>';
        html += '<span class="text-amber-400/70 font-mono">' + esc(t.command) + '</span>';
        html += '</div>';
      });
      html += '</div>';
    }
    html += '</div></div>';
    return html;
  }

  function sectionQueries(queries) {
    if (!queries || queries.length === 0) return "";
    var html = '<div>';
    html += heading("Queries");
    html += '<div class="flex flex-wrap gap-2">';
    queries.forEach(function (q) {
      var name = typeof q === "string" ? q : q.name;
      html += '<span class="bg-white/8 text-white/70 text-xs px-2.5 py-1 rounded font-mono">' + esc(name) + '</span>';
    });
    html += '</div></div>';
    return html;
  }

  function sectionPolicies(policies) {
    if (!policies || policies.length === 0) return "";
    var html = '<div>';
    html += heading("Policies");
    html += '<div class="space-y-2">';
    policies.forEach(function (p) {
      html += '<div class="flex items-center gap-2 bg-white/[.02] border border-white/8 rounded px-3 py-2 text-sm">';
      html += '<span class="text-amber-400 text-xs">\u26A1</span>';
      html += '<span class="text-white/87">' + esc(p.name) + '</span>';
      html += '<span class="text-white/38 text-xs ml-auto">on</span>';
      html += '<span class="text-amber-400/70 text-xs font-mono">' + esc(p.event) + '</span>';
      html += '<span class="text-white/38 text-xs">\u2192</span>';
      html += '<span class="text-[#4361ee]/70 text-xs font-mono">' + esc(p.trigger) + '</span>';
      html += '</div>';
    });
    html += '</div></div>';
    return html;
  }

  function heading(text) {
    return '<h2 class="text-[#4361ee] text-sm font-semibold uppercase tracking-wider mb-2">' + esc(text) + '</h2>';
  }

  R.renderAggregateDetail = renderAggregateDetail;
})();
