// HecksAppeal IDE — HTML Builders (Panels)
//
// Builds HTML strings for console, agent chat, glossary,
// and analysis panels. Extends HecksRenderer from renderer.js.
//
//   Usage:
//     HecksRenderer.renderCommandForms(domain);
//     HecksRenderer.renderAgentMessage("user", "Hello");
//

(function () {
  "use strict";

  var R = window.HecksRenderer;
  var escapeHtml = R.escapeHtml;

  function renderCommandForms(domain) {
    var container = document.getElementById("console-content");
    if (!container) return;
    var aggregates = domain && domain.aggregates ? domain.aggregates : [];
    if (aggregates.length === 0) {
      container.innerHTML = '<p class="text-white/[.38] text-sm">No aggregates found</p>';
      return;
    }
    var html = '<div class="space-y-2">';
    aggregates.forEach(function (agg) {
      html += renderAggregateSection(agg);
    });
    html += '</div>';
    container.innerHTML = html;
    bindConsoleForms(container);
    bindCollapsibles(container);
  }

  function renderAggregateSection(agg) {
    var commands = (agg.commands || []).map(function (c) {
      return typeof c === "string" ? { name: c, attributes: [] } : c;
    });
    var html = '<details class="border border-white/[.12] rounded" open>';
    html += '<summary class="cursor-pointer px-3 py-1.5 text-sm font-semibold text-white/[.87] ';
    html += 'hover:bg-white/[.04] select-none">' + escapeHtml(agg.name) + '</summary>';
    html += '<div class="px-3 pb-2 space-y-2">';
    commands.forEach(function (cmd) {
      html += renderCommandForm(agg.name, cmd);
    });
    if (commands.length === 0) {
      html += '<p class="text-white/[.38] text-xs py-1">No commands</p>';
    }
    html += '</div></details>';
    return html;
  }

  function renderCommandForm(aggName, cmd) {
    var attrs = cmd.attributes || [];
    var html = '<form data-console-form data-aggregate="' + escapeHtml(aggName);
    html += '" data-command="' + escapeHtml(cmd.name) + '" class="py-1">';
    html += '<div class="flex items-center gap-2 flex-wrap">';
    html += '<span class="text-white/[.87] text-xs font-medium w-28 flex-shrink-0">' + escapeHtml(cmd.name) + '</span>';
    attrs.forEach(function (a) {
      var inputType = a.type === "Integer" || a.type === "Float" ? "number" : "text";
      html += '<label class="flex items-center gap-1 text-xs text-white/[.54]">';
      html += escapeHtml(a.name) + ':';
      html += '<input type="' + inputType + '" name="' + escapeHtml(a.name) + '" ';
      html += 'class="bg-elevated border border-white/[.12] rounded px-1.5 py-0.5 text-xs ';
      html += 'text-white/[.87] w-24 focus:outline-none focus:border-accent" /></label>';
    });
    html += '<button type="submit" class="bg-[#4361ee] hover:bg-[#5a7df7] text-white ';
    html += 'text-xs px-2 py-0.5 rounded transition-colors flex-shrink-0">Dispatch</button>';
    html += '</div><div class="console-result text-xs mt-0.5" data-result></div></form>';
    return html;
  }

  function bindConsoleForms(container) {
    container.querySelectorAll("form[data-console-form]").forEach(function (form) {
      form.addEventListener("submit", function (e) {
        e.preventDefault();
        var agg = form.dataset.aggregate;
        var cmd = form.dataset.command;
        var values = {};
        form.querySelectorAll("input[name]").forEach(function (inp) {
          if (inp.value) values[inp.name] = inp.type === "number" ? Number(inp.value) : inp.value;
        });
        var resultEl = form.querySelector("[data-result]");
        if (window.Hecks && window.Hecks.dispatch) {
          var result = window.Hecks.dispatch(agg, cmd, values);
          if (resultEl) showResult(resultEl, agg, cmd, values, result);
        }
      });
    });
  }

  function showResult(el, agg, cmd, values, result) {
    var eventData = result && result.data ? JSON.stringify(result.data) : JSON.stringify(values);
    var eventName = result && result.event ? result.event : cmd.replace(/^[A-Z][a-z]+/, function (v) { return v + "d"; });
    el.innerHTML = '<span class="text-green-400">OK ' + escapeHtml(eventName) + ' ' + escapeHtml(eventData) + '</span>';
  }

  function bindCollapsibles(container) {
    container.querySelectorAll("details > summary").forEach(function (s) {
      s.addEventListener("click", function (e) { e.stopPropagation(); });
    });
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

  R.renderCommandForms = renderCommandForms;
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
