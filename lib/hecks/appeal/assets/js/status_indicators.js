// HecksAppeal IDE — Status Indicators
//
// UI update helpers for screenshot status and agent adapter toggle.
// Attached to window.HecksStatus for use by app.js event handling.
//
//   HecksStatus.flashScreenshot(state);
//   HecksStatus.updateAdapterToggle("live");
//

(function () {
  "use strict";

  function flashScreenshot(state) {
    state.screenshotCount++;
    var el = document.getElementById("screenshot-status");
    if (!el) return;
    var dot = el.querySelector(".screenshot-dot");
    var label = el.querySelector(".screenshot-label");
    if (dot) dot.className = "screenshot-dot w-2 h-2 rounded-full bg-green-500 flex-shrink-0 transition-all duration-300";
    if (label) label.textContent = "Screenshot #" + state.screenshotCount;
    clearTimeout(state._screenshotTimer);
    state._screenshotTimer = setTimeout(function () {
      if (dot) dot.className = "screenshot-dot w-2 h-2 rounded-full bg-green-500/50 flex-shrink-0 transition-all duration-300";
    }, 500);
  }

  function setupScreenshotToggle() {
    var el = document.getElementById("screenshot-status");
    if (!el) return;
    el.addEventListener("click", function () {
      var label = el.querySelector(".screenshot-label");
      if (!label) return;
      var isOpen = label.style.maxWidth !== "0px" && label.style.maxWidth !== "0";
      if (isOpen) {
        label.style.maxWidth = "0";
        label.style.opacity = "0";
        label.style.marginLeft = "0";
      } else {
        label.style.maxWidth = "10rem";
        label.style.opacity = "1";
        label.style.marginLeft = "0.375rem";
      }
    });
  }

  function updateAdapterToggle(mode) {
    var label = document.getElementById("agent-mode-label");
    var btn = document.getElementById("agent-mode-toggle");
    if (label) label.textContent = mode;
    if (btn) btn.textContent = mode === "memory" ? "Switch to live" : "Switch to memory";
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", setupScreenshotToggle);
  } else {
    setupScreenshotToggle();
  }

  window.HecksStatus = {
    flashScreenshot: flashScreenshot,
    updateAdapterToggle: updateAdapterToggle
  };
})();
