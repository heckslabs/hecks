// HecksAppeal IDE — HTML Builders (Panels)
//
// Builds HTML strings for console, agent chat, glossary,
// and analysis panels. Extends HecksRenderer from renderer.js.
//
//   Usage:
//     HecksRenderer.renderConsole(aggregates, "Order", "Create");
//     HecksRenderer.renderAgentMessage("user", "Hello");
//

(function () {
  "use strict";

  var R = window.HecksRenderer;
  var escapeHtml = R.escapeHtml;

  function renderConsole(aggregates, selectedAgg, selectedCmd) {
    var container = document.getElementById("console-content");
    if (!container) return;
    var html = '<div class="p-3 space-y-3">';
    html += '<div class="flex gap-3">';
    html += '<label class="text-white/54 text-sm" for="console-aggregate">Aggregate</label>';
    html += '<select id="console-aggregate" name="aggregate" role="listbox" aria-label="Select aggregate" ';
    html += 'class="bg-[#1a1a2e] text-white/87 text-sm border border-white/12 rounded px-2 py-1 flex-1">';
    html += '<option value="">-- select --</option>';
    if (aggregates) {
      aggregates.forEach(function (agg) {
        var name = typeof agg === "string" ? agg : agg.name;
        var sel = name === selectedAgg ? " selected" : "";
        html += '<option value="' + escapeHtml(name) + '"' + sel + '>' + escapeHtml(name) + '</option>';
      });
    }
    html += '</select></div>';
    html += renderCommandSelect(aggregates, selectedAgg, selectedCmd);
    html += renderCommandForm(aggregates, selectedAgg, selectedCmd);
    html += '</div>';
    container.innerHTML = html;
  }

  function renderCommandSelect(aggregates, selectedAgg, selectedCmd) {
    var commands = findCommands(aggregates, selectedAgg);
    var html = '<div class="flex gap-3">';
    html += '<label class="text-white/54 text-sm" for="console-command">Command</label>';
    html += '<select id="console-command" name="command" role="listbox" aria-label="Select command" ';
    html += 'class="bg-[#1a1a2e] text-white/87 text-sm border border-white/12 rounded px-2 py-1 flex-1">';
    html += '<option value="">-- select --</option>';
    commands.forEach(function (cmd) {
      var sel = cmd === selectedCmd ? " selected" : "";
      html += '<option value="' + escapeHtml(cmd) + '"' + sel + '>' + escapeHtml(cmd) + '</option>';
    });
    html += '</select></div>';
    return html;
  }

  function renderCommandForm(aggregates, selectedAgg, selectedCmd) {
    if (!selectedAgg || !selectedCmd) return "";
    var html = '<form data-console-form class="space-y-2 border-t border-white/12 pt-3 mt-3">';
    html += '<input type="hidden" name="aggregate" value="' + escapeHtml(selectedAgg) + '">';
    html += '<input type="hidden" name="command" value="' + escapeHtml(selectedCmd) + '">';
    html += '<p class="text-white/54 text-xs">Submit fields as JSON via the command bus.</p>';
    html += '<button type="submit" role="button" aria-label="Execute command" ';
    html += 'class="bg-[#4361ee] hover:bg-[#5a7df7] text-white text-sm px-4 py-1.5 rounded transition-colors">';
    html += 'Execute ' + escapeHtml(selectedCmd) + '</button>';
    html += '</form>';
    return html;
  }

  function findCommands(aggregates, selectedAgg) {
    if (!aggregates || !selectedAgg) return [];
    var match = aggregates.find(function (a) {
      var name = typeof a === "string" ? a : a.name;
      return name === selectedAgg;
    });
    if (!match || typeof match === "string") return [];
    return match.commands || [];
  }

  function renderAgentMessage(role, content) {
    var container = document.getElementById("agent-messages");
    if (!container) return;
    var isUser = role === "user";
    var align = isUser ? "justify-end" : "justify-start";
    var bg = isUser ? "bg-[#4361ee]" : "bg-[#1a1a2e]";
    var html = '<div class="flex ' + align + ' mb-2" role="log">';
    html += '<div class="' + bg + ' text-white/[.87] text-sm rounded-lg px-3 py-2 max-w-[80%] whitespace-pre-wrap">';
    html += escapeHtml(content || "");
    html += '</div></div>';
    container.insertAdjacentHTML("beforeend", html);
    container.scrollTop = container.scrollHeight;
  }

  function renderGlossary(terms) {
    var container = document.getElementById("glossary-content");
    if (!container) return;
    var html = '<table class="w-full text-sm" role="table">';
    html += '<thead><tr class="border-b border-white/12">';
    html += '<th class="text-left text-white/54 px-3 py-2">Term</th>';
    html += '<th class="text-left text-white/54 px-3 py-2">Kind</th>';
    html += '<th class="text-left text-white/54 px-3 py-2">Description</th>';
    html += '</tr></thead><tbody>';
    if (terms && terms.length > 0) {
      terms.forEach(function (term) {
        html += '<tr class="border-b border-white/8 hover:bg-white/4">';
        html += '<td class="text-white/87 px-3 py-1.5">' + escapeHtml(term.name) + '</td>';
        html += '<td class="text-white/54 px-3 py-1.5">' + escapeHtml(term.kind) + '</td>';
        html += '<td class="text-white/54 px-3 py-1.5">' + escapeHtml(term.description) + '</td>';
        html += '</tr>';
      });
    }
    html += '</tbody></table>';
    container.innerHTML = html;
  }

  function renderAnalysis(stats, domains) {
    var container = document.getElementById("analysis-content");
    if (!container) return;
    var html = '<div class="space-y-4 p-3">';
    if (stats) {
      html += '<table class="w-full text-sm mb-4" role="table">';
      html += '<thead><tr class="border-b border-white/12">';
      html += '<th class="text-left text-white/54 px-3 py-2">Metric</th>';
      html += '<th class="text-left text-white/54 px-3 py-2">Value</th>';
      html += '</tr></thead><tbody>';
      Object.keys(stats).forEach(function (key) {
        html += '<tr class="border-b border-white/8">';
        html += '<td class="text-white/87 px-3 py-1.5">' + escapeHtml(key) + '</td>';
        html += '<td class="text-white/54 px-3 py-1.5">' + escapeHtml(String(stats[key])) + '</td>';
        html += '</tr>';
      });
      html += '</tbody></table>';
    }
    if (domains && domains.length > 0) {
      domains.forEach(function (d) {
        html += '<div class="mb-2">';
        html += '<h4 class="text-white/87 text-sm font-medium mb-1">' + escapeHtml(d.name) + '</h4>';
        if (d.aggregates) {
          d.aggregates.forEach(function (a) {
            html += '<span class="inline-block bg-[#16213e] text-white/54 text-xs px-2 py-0.5 rounded mr-1 mb-1">';
            html += escapeHtml(a.name || a) + '</span>';
          });
        }
        html += '</div>';
      });
    }
    html += '</div>';
    container.innerHTML = html;
  }

  R.renderConsole = renderConsole;
  function renderAgentThinking(thinking) {
    var container = document.getElementById("agent-messages");
    if (!container) return;
    var existing = document.getElementById("agent-thinking");
    if (thinking) {
      if (existing) return;
      var html = '<div id="agent-thinking" class="flex justify-start mb-2">';
      html += '<div class="bg-[#1a1a2e] text-white/[.54] text-sm rounded-lg px-3 py-2 flex items-center gap-1.5">';
      html += '<span class="animate-pulse">Thinking</span>';
      html += '<span class="inline-flex gap-0.5"><span class="w-1 h-1 bg-white/[.38] rounded-full animate-bounce [animation-delay:0ms]"></span>';
      html += '<span class="w-1 h-1 bg-white/[.38] rounded-full animate-bounce [animation-delay:150ms]"></span>';
      html += '<span class="w-1 h-1 bg-white/[.38] rounded-full animate-bounce [animation-delay:300ms]"></span></span>';
      html += '</div></div>';
      container.insertAdjacentHTML("beforeend", html);
      container.scrollTop = container.scrollHeight;
    } else {
      if (existing) existing.remove();
    }
  }

  R.renderAgentMessage = renderAgentMessage;
  R.renderAgentThinking = renderAgentThinking;
  R.renderGlossary = renderGlossary;
  R.renderAnalysis = renderAnalysis;
})();
