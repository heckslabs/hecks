// HecksAppeal IDE — Panel Resize Handles
//
// @domain Layout.ResizePanel
//
// Enables drag-to-resize for sidebar, right panel, and events panel.
// Each handle is a thin bar that highlights on hover and drives
// width/height changes on mousedown+mousemove.
//
//   Handles:
//     [data-resize="sidebar-x"]  — sidebar width
//     [data-resize="right-x"]    — right panel width
//     [data-resize="events-y"]   — events panel height
//

(function () {
  "use strict";

  var MIN_PX = 80;

  function init() {
    document.querySelectorAll("[data-resize]").forEach(function (handle) {
      handle.addEventListener("mousedown", function (e) {
        e.preventDefault();
        startDrag(handle, e);
      });
    });
  }

  function startDrag(handle, startEvent) {
    var kind = handle.dataset.resize;
    var startX = startEvent.clientX;
    var startY = startEvent.clientY;
    var target, startSize;

    if (kind === "sidebar-x") {
      target = document.getElementById("sidebar");
      startSize = target.offsetWidth;
    } else if (kind === "right-x") {
      target = document.getElementById("right-panel");
      startSize = target.offsetWidth;
    } else if (kind === "events-y") {
      target = document.getElementById("events-panel");
      startSize = target.offsetHeight;
    }

    if (!target) return;

    handle.classList.add("bg-accent/60");
    document.body.style.cursor = kind.endsWith("-x") ? "col-resize" : "row-resize";
    document.body.style.userSelect = "none";

    var overlay = document.createElement("div");
    overlay.style.cssText = "position:fixed;inset:0;z-index:9999;cursor:" + document.body.style.cursor;
    document.body.appendChild(overlay);

    function onMove(e) {
      if (kind === "sidebar-x") {
        var dx = e.clientX - startX;
        target.style.width = Math.max(MIN_PX, startSize + dx) + "px";
      } else if (kind === "right-x") {
        var dx2 = startX - e.clientX;
        target.style.width = Math.max(MIN_PX, startSize + dx2) + "px";
      } else if (kind === "events-y") {
        var dy = startY - e.clientY;
        target.style.height = Math.max(MIN_PX, startSize + dy) + "px";
      }
    }

    function onUp() {
      document.removeEventListener("mousemove", onMove);
      document.removeEventListener("mouseup", onUp);
      document.body.removeChild(overlay);
      handle.classList.remove("bg-accent/60");
      document.body.style.cursor = "";
      document.body.style.userSelect = "";
    }

    document.addEventListener("mousemove", onMove);
    document.addEventListener("mouseup", onUp);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
