// HecksAppeal IDE — Feature Management Panel
//
// @domain Feature.ProposeFeature, Feature.PlanAdditions, Feature.VerifyAdditions, Feature.AcceptFeature
//
// Manages the feature lifecycle: create, plan (AI), build (AI),
// verify additions against the domain. Dispatches through
// Hecks.dispatch() and listens for domain events via HecksApp.
//
//   dispatch("Feature", "ProposeFeature", { title: "..." })
//

(function () {
  "use strict";

  var features = [];
  var selectedFeatureId = null;

  function dispatch(aggregate, command, args) {
    if (window.Hecks && window.Hecks.dispatch) {
      return window.Hecks.dispatch(aggregate, command, args || {});
    }
  }

  // -- Status badge rendering --

  var STATUS_COLORS = {
    draft: "bg-white/[.12] text-white/[.54]",
    planned: "bg-blue-500/20 text-blue-400",
    building: "bg-yellow-500/20 text-yellow-400",
    done: "bg-green-500/20 text-green-400"
  };

  function statusBadge(status) {
    var cls = STATUS_COLORS[status] || STATUS_COLORS.draft;
    return '<span class="px-2 py-0.5 text-xs font-medium rounded ' + cls + '">' +
      status.toUpperCase() + '</span>';
  }

  // -- Progress bar --

  function progressBar(completed, total) {
    var pct = total > 0 ? Math.round((completed / total) * 100) : 0;
    return '<div class="flex items-center gap-2 mt-1">' +
      '<div class="flex-1 h-1.5 bg-white/[.08] rounded-full overflow-hidden">' +
      '<div class="h-full bg-accent rounded-full transition-all" style="width:' + pct + '%"></div>' +
      '</div>' +
      '<span class="text-xs text-white/[.38]">' + completed + '/' + total + ' additions</span>' +
      '</div>';
  }

  // -- Render feature list --

  function renderFeatureList() {
    var container = document.getElementById("feature-list");
    if (!container) return;

    if (features.length === 0) {
      container.innerHTML = '<p class="text-white/[.38] text-sm">No features yet. Click "New Feature" to start planning.</p>';
      return;
    }

    var html = "";
    features.forEach(function (f) {
      var completed = (f.additions || []).filter(function (a) { return a.exists; }).length;
      var total = (f.additions || []).length;
      var isSelected = f.id === selectedFeatureId;
      var border = isSelected ? "border-accent" : "border-white/[.12]";

      html += '<div class="feature-card rounded-lg border ' + border + ' bg-elevated p-3 cursor-pointer" data-feature-id="' + f.id + '">' +
        '<div class="flex items-center justify-between mb-1">' +
        '<span class="text-sm font-medium text-white/[.87] truncate mr-2">' + escapeHtml(f.title) + '</span>' +
        statusBadge(f.status) +
        '</div>' +
        progressBar(completed, total) +
        '<div class="flex gap-2 mt-2">' +
        '<button class="px-2 py-1 text-xs bg-blue-500/20 text-blue-400 hover:bg-blue-500/30 rounded transition-colors" data-feature-action="plan" data-feature-id="' + f.id + '">Plan AI</button>' +
        '<button class="px-2 py-1 text-xs bg-yellow-500/20 text-yellow-400 hover:bg-yellow-500/30 rounded transition-colors" data-feature-action="build" data-feature-id="' + f.id + '">Build AI</button>' +
        '<button class="px-2 py-1 text-xs bg-green-500/20 text-green-400 hover:bg-green-500/30 rounded transition-colors" data-feature-action="verify" data-feature-id="' + f.id + '">Verify</button>' +
        '</div>';

      if (isSelected && f.additions && f.additions.length > 0) {
        html += renderAdditions(f.additions);
      }

      html += '</div>';
    });

    container.innerHTML = html;
  }

  // -- Render additions checklist --

  function renderAdditions(additions) {
    var html = '<div class="mt-3 pt-2 border-t border-white/[.08] space-y-1">';
    additions.forEach(function (a) {
      var icon = a.exists ? '<span class="text-green-400">&#x2705;</span>' : '<span class="text-white/[.24]">&#x2B1C;</span>';
      var textCls = a.exists ? "text-white/[.87]" : "text-white/[.54]";
      html += '<div class="flex items-center gap-2 text-xs ' + textCls + '">' +
        icon + ' <span class="text-white/[.38]">' + escapeHtml(a.kind) + ':</span> ' + escapeHtml(a.name) +
        '</div>';
    });
    html += '</div>';
    return html;
  }

  // -- Setup interactions --

  function setupFeatures() {
    document.addEventListener("click", function (e) {
      var newBtn = e.target.closest("[data-action='new-feature']");
      if (newBtn) {
        var title = prompt("Feature title:");
        if (!title || !title.trim()) return;
        var description = prompt("Brief description (optional):") || "";
        dispatch("Feature", "ProposeFeature", { title: title.trim(), description: description.trim() });
        return;
      }

      var actionBtn = e.target.closest("[data-feature-action]");
      if (actionBtn) {
        var action = actionBtn.dataset.featureAction;
        var id = actionBtn.dataset.featureId;
        var feature = features.find(function(f) { return f.id === id; });
        if (!feature) return;

        if (action === "plan") {
          actionBtn.textContent = "Planning...";
          sendToBuilder("plan", { title: feature.title, description: feature.description }, function(result) {
            if (result.additions) {
              handleFeatureEvent({ event: "AdditionsPlanned", data: { feature_id: id, additions: result.additions } });
            }
          });
        }
        if (action === "build") {
          actionBtn.textContent = "Building...";
          sendToBuilder("build", { additions: feature.additions }, function(result) {
            if (result.file) {
              handleFeatureEvent({ event: "AdditionsPlanned", data: { feature_id: id, additions: feature.additions } });
              // Trigger verify after build
              setTimeout(function() {
                sendToBuilder("verify", { additions: feature.additions }, function(vr) {
                  if (vr.additions) handleFeatureEvent({ event: "AdditionsVerified", data: { feature_id: id, additions: vr.additions } });
                  if (vr.complete) handleFeatureEvent({ event: "FeatureAccepted", data: { feature_id: id } });
                });
              }, 1000);
            }
          });
        }
        if (action === "verify") {
          sendToBuilder("verify", { additions: feature.additions }, function(result) {
            if (result.additions) handleFeatureEvent({ event: "AdditionsVerified", data: { feature_id: id, additions: result.additions } });
            if (result.complete) handleFeatureEvent({ event: "FeatureAccepted", data: { feature_id: id } });
          });
        }
        return;
      }

      var card = e.target.closest(".feature-card");
      if (card) {
        selectedFeatureId = card.dataset.featureId;
        renderFeatureList();
      }
    });
  }

  // -- Event handling (called from app.js) --

  function handleFeatureEvent(event) {
    var d = event.data || {};
    switch (event.event) {
      case "FeatureProposed":
        features.push({
          id: d.feature_id || String(Date.now()),
          title: d.title, description: d.description || "",
          status: "draft", additions: []
        });
        selectedFeatureId = features[features.length - 1].id;
        renderFeatureList();
        break;
      case "AdditionsPlanned":
        updateFeature(d.feature_id, { status: "planned", additions: d.additions || [] });
        renderFeatureList();
        break;
      case "AdditionsVerified":
        updateFeature(d.feature_id, { additions: d.additions || [] });
        renderFeatureList();
        break;
      case "FeatureAccepted":
        updateFeature(d.feature_id, { status: "done" });
        renderFeatureList();
        break;
    }
  }

  function updateFeature(id, attrs) {
    features.forEach(function (f) {
      if (f.id === id) Object.assign(f, attrs);
    });
  }

  var pendingCallbacks = {};

  function sendToBuilder(action, data, callback) {
    var id = String(Date.now());
    pendingCallbacks[action] = callback;
    if (window.HecksIDE && window.HecksIDE.raw) {
      window.HecksIDE.raw(JSON.stringify({ type: "app_builder", action: action, title: data.title, description: data.description, additions: data.additions }));
    }
  }

  // Listen for app_builder results from server
  var origSocketRoute = window.HecksApp && window.HecksApp.handleEvent;
  if (window.HecksApp) {
    var origHandler = window.HecksApp.handleEvent;
    window.HecksApp.handleEvent = function(event) {
      if (event.type === "app_builder_result" && event.action && pendingCallbacks[event.action]) {
        pendingCallbacks[event.action](event.data || {});
        delete pendingCallbacks[event.action];
        return;
      }
      origHandler(event);
    };
  }

  function escapeHtml(str) {
    var div = document.createElement("div");
    div.appendChild(document.createTextNode(str));
    return div.innerHTML;
  }

  // -- Init --

  function init() {
    setupFeatures();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }

  window.HecksFeatures = {
    handleEvent: handleFeatureEvent,
    getFeatures: function () { return features; }
  };
})();
