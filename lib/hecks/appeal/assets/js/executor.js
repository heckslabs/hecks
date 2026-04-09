// HecksAppeal IDE — Product Executor
//
// @domain ProductExecutor.SendToAgent, ProductExecutor.SwitchAgent, ProductExecutor.ClearAgent
//
// Single chat interface for the product team. Describe a feature,
// agents collaborate until it ships, then it becomes a feature-flagged
// button on the dashboard.
//

(function () {
  "use strict";

  var shipped = [];
  var activeAgent = "chris";

  var AGENT_COLORS = {
    chris: "#8b5cf6", jesper: "#f59e0b", alberto: "#ef4444",
    eric: "#3b82f6", alistair: "#10b981", uncle_bob: "#6366f1",
    don: "#ec4899", jony: "#f97316"
  };

  var AGENT_TITLES = {
    chris: "Scrum Master", jesper: "Product Owner", alberto: "Event Storming",
    eric: "Planner", alistair: "Domain Builder", uncle_bob: "App Builder",
    don: "UX", jony: "UI"
  };

  function sendMessage() {
    var input = document.getElementById("executor-input");
    if (!input || !input.value.trim()) return;
    var content = input.value.trim();
    input.value = "";

    appendMessage("you", "user", content);

    // Dispatch as domain command so it shows in events panel
    if (window.HecksWebClientState && window.HecksWebClientState.dispatch) {
      window.HecksWebClientState.dispatch("ProductExecutor", "SendToAgent", { agent_name: activeAgent, content: content });
    } else if (window.HecksIDE && window.HecksIDE.command) {
      window.HecksIDE.command("ProductExecutor", "SendToAgent", { agent_name: activeAgent, content: content });
    }

    // Also send executor message for the agent runner
    if (window.HecksIDE && window.HecksIDE.raw) {
      window.HecksIDE.raw(JSON.stringify({
        type: "executor", agent: activeAgent, content: content
      }));
    }
  }

  function appendMessage(agent, role, content) {
    var container = document.getElementById("executor-messages");
    if (!container) return;

    var color = AGENT_COLORS[agent] || "#9ca3af";
    var label = role === "user" ? "You" : capitalize(agent);
    var initial = role === "user" ? "Y" : label.charAt(0);
    var isUser = role === "user";

    var align = isUser ? "flex-row-reverse" : "flex-row";
    var bubble = isUser
      ? "bg-accent text-white rounded-2xl rounded-br-sm"
      : "bg-elevated text-white/[.87] rounded-2xl rounded-bl-sm";

    var avatar = '<div class="w-7 h-7 rounded-full flex items-center justify-center text-xs font-bold flex-shrink-0" ' +
      'style="background: ' + color + ';">' + initial + "</div>";
    var nameTag = isUser ? "" : '<span class="text-[10px] font-medium mb-0.5 block" style="color: ' + color + ';">' + label + "</span>";

    var msgId = "msg-" + Date.now() + "-" + Math.random().toString(36).slice(2, 6);
    var reactions = '<div class="reactions flex gap-0.5 mt-1" data-msg="' + msgId + '"></div>';
    var tapbacks = '<div class="tapback-bar hidden absolute -top-7 left-0 flex gap-0.5 bg-elevated rounded-full px-1 py-0.5 shadow-lg border border-white/[.12] z-10">' +
      tapbackButtons(msgId) + "</div>";

    container.insertAdjacentHTML("beforeend",
      '<div class="flex gap-2 ' + align + " " + (isUser ? "pl-12" : "pr-12") + '">' +
      avatar +
      '<div class="relative group">' +
      '<div id="' + msgId + '" class="' + bubble + ' px-3 py-2 text-sm max-w-[80%] cursor-pointer">' +
      nameTag + escapeHtml(content) + "</div>" +
      tapbacks + reactions +
      "</div></div>"
    );

    bindTapback(msgId);
    container.scrollTop = container.scrollHeight;
  }

  function shipFeature(title) {
    shipped.push({ title: title, enabled: true });
    renderDashboard();
  }

  function renderDashboard() {
    var dash = document.getElementById("executor-dashboard");
    if (!dash) return;

    var heading = '<h3 class="text-xs font-semibold text-white/[.38] px-1 mb-1">Shipped</h3>';
    var buttons = shipped.map(function (f, i) {
      var bg = f.enabled ? "bg-accent" : "bg-white/[.08]";
      var text = f.enabled ? "text-white" : "text-white/[.38]";
      return '<button class="w-full text-left px-2 py-1.5 text-xs rounded ' + bg + " " + text +
        ' transition-colors" data-feature-flag="' + i + '">' +
        escapeHtml(f.title) + "</button>";
    }).join("");

    dash.innerHTML = heading + buttons;

    dash.querySelectorAll("[data-feature-flag]").forEach(function (btn) {
      btn.addEventListener("click", function () {
        var idx = parseInt(btn.dataset.featureFlag);
        shipped[idx].enabled = !shipped[idx].enabled;
        renderDashboard();
        broadcastFlags();
      });
    });
  }

  function broadcastFlags() {
    if (window.HecksIDE && window.HecksIDE.raw) {
      window.HecksIDE.raw(JSON.stringify({
        type: "feature_flags",
        flags: shipped.map(function (f) { return { title: f.title, enabled: f.enabled }; })
      }));
    }
  }

  function handleEvent(data) {
    if (data.type === "executor_message") {
      appendMessage(data.agent, data.role || "assistant", data.content);
      if (data.shipped) shipFeature(data.shipped);
    }
    if (data.type === "executor_thinking") {
      setThinking(data.agent, data.thinking);
    }
  }

  function setThinking(agent, thinking) {
    var container = document.getElementById("executor-messages");
    if (!container) return;
    var id = "thinking-" + agent;
    var existing = document.getElementById(id);

    if (thinking && !existing) {
      var color = AGENT_COLORS[agent] || "#9ca3af";
      var initial = capitalize(agent).charAt(0);
      container.insertAdjacentHTML("beforeend",
        '<div id="' + id + '" class="flex gap-2 pr-12">' +
        '<div class="w-7 h-7 rounded-full flex items-center justify-center text-xs font-bold flex-shrink-0 animate-pulse" style="background: ' + color + ';">' + initial + '</div>' +
        '<div class="bg-elevated rounded-2xl rounded-bl-sm px-3 py-2 text-sm text-white/[.38]">' +
        '<span class="inline-flex gap-1"><span class="animate-bounce" style="animation-delay:0s">.</span><span class="animate-bounce" style="animation-delay:0.15s">.</span><span class="animate-bounce" style="animation-delay:0.3s">.</span></span>' +
        '</div></div>'
      );
      container.scrollTop = container.scrollHeight;
    }
    if (!thinking && existing) existing.remove();
  }

  var TAPBACKS = [
    { emoji: "\u2764\ufe0f", label: "love" },
    { emoji: "\ud83d\udc4d", label: "thumbs up" },
    { emoji: "\ud83d\udc4e", label: "thumbs down" },
    { emoji: "\ud83d\ude02", label: "laugh" },
    { emoji: "!!", label: "emphasize" },
    { emoji: "?", label: "question" }
  ];

  function tapbackButtons(msgId) {
    return TAPBACKS.map(function (tb) {
      return '<button class="text-xs px-1 hover:scale-125 transition-transform" ' +
        'data-tapback="' + tb.label + '" data-target="' + msgId + '" ' +
        'aria-label="React with ' + tb.label + '">' + tb.emoji + '</button>';
    }).join("");
  }

  function bindTapback(msgId) {
    var msgEl = document.getElementById(msgId);
    if (!msgEl) return;

    msgEl.addEventListener("click", function () {
      var bar = msgEl.parentElement.querySelector(".tapback-bar");
      if (bar) bar.classList.toggle("hidden");
    });

    var bar = msgEl.parentElement.querySelector(".tapback-bar");
    if (!bar) return;
    bar.querySelectorAll("[data-tapback]").forEach(function (btn) {
      btn.addEventListener("click", function (e) {
        e.stopPropagation();
        var emoji = btn.textContent;
        var reactionsEl = msgEl.parentElement.querySelector(".reactions");
        reactionsEl.insertAdjacentHTML("beforeend",
          '<span class="text-xs bg-white/[.08] rounded-full px-1.5 py-0.5">' + emoji + '</span>'
        );
        bar.classList.add("hidden");
      });
    });
  }

  function capitalize(s) {
    if (s === "uncle_bob") return "Uncle Bob";
    return s.charAt(0).toUpperCase() + s.slice(1);
  }

  function escapeHtml(str) {
    if (!str) return "";
    return str.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }

  function setup() {
    var sendBtn = document.querySelector('[data-action="send-executor"]');
    if (sendBtn) sendBtn.addEventListener("click", sendMessage);

    var input = document.getElementById("executor-input");
    if (input) {
      input.addEventListener("keydown", function (e) {
        if (e.key === "Enter") { e.preventDefault(); sendMessage(); }
      });
    }
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", setup);
  } else {
    setup();
  }

  window.HecksExecutor = {
    handleEvent: handleEvent,
    shipFeature: shipFeature,
    getShipped: function () { return shipped; }
  };
})();
